// Worker/BoundedPipeRead.swift
//
// Deadline-bounded synchronous pipe drain, shared by the subprocess helpers
// that must read a child's output to EOF without risking an unbounded block
// on a cooperative-pool thread (issue #1233).
//
// EOF on a pipe requires every duplicate of the write end to be closed. A
// process spawned concurrently with the child — another job's fork, a test's
// HTTP server — that inherited a non-CLOEXEC duplicate postpones EOF until
// *it* exits, so a plain `readDataToEndOfFile()` is an unbounded stall in
// exactly the loaded-parallel-CI conditions of issues #1139/#1233. Pair with
// `setCloseOnExec(_:)` on the pipe so the leak cannot happen; the deadline
// here is defence in depth for descriptors leaked by code outside our
// control.

// `setCloseOnExec(_:)` used to live here. It moved to
// `Sources/Core/PipeCloseOnExec.swift` when the server-side zip and notebook
// helpers needed it too — `Core` is the lowest module all three can reach, and
// re-exported via this target's `import Core`, so worker call sites are
// unchanged.

import Core
import Foundation

#if os(Linux)
import Glibc
#endif

/// Reads from `descriptor` until EOF or `deadline`, whichever comes first,
/// and returns whatever accumulated (capped at `maxBytes`; excess is
/// discarded, mirroring `CapturedPipeBuffer`'s OOM guard). The poll
/// granularity is 100 ms, so the calling thread is parked in `read(2)` only
/// while data is actually available — never in an unbounded blocking read.
func boundedReadToEOF(
    fromDescriptor descriptor: Int32,
    deadline: Date,
    maxBytes: Int = 1_048_576
) -> Data {
    var accumulated = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let readyCount = poll(&pollDescriptor, 1, 100)
        if readyCount == -1 {
            if errno == EINTR { continue }
            return accumulated
        }
        if readyCount > 0 {
            let bytesRead = read(descriptor, &chunk, chunk.count)
            if bytesRead > 0 {
                let remaining = maxBytes - accumulated.count
                if remaining > 0 {
                    accumulated.append(contentsOf: chunk[0..<min(bytesRead, remaining)])
                }
                continue
            }
            if bytesRead == -1 && errno == EINTR { continue }
            return accumulated  // 0 = EOF (every write end closed); -1 = unrecoverable.
        }
        if Date() >= deadline { return accumulated }
    }
}

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

import Foundation

#if os(Linux)
import Glibc
#endif

/// Foundation's `Pipe` does not set `FD_CLOEXEC` (verified on Swift 6.3 /
/// glibc 2.39 and Darwin). Without it, any subprocess spawned concurrently
/// with this run inherits duplicates of these descriptors across its exec,
/// and the read side then never sees EOF until that unrelated process exits
/// (issue #1139's cross-test stall). The intended child still receives its
/// ends: `dup2`/spawn file actions clear the flag on the duplicate they
/// install.
///
/// Every worker-side subprocess pipe should go through this — a single
/// non-CLOEXEC pipe elsewhere re-opens the EOF-starvation window for everyone
/// (issue #1233). The script-execution path no longer builds pipes by hand,
/// but the capability probes and the MIME detector still do.
func setCloseOnExec(_ pipe: Pipe) {
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else { continue }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}

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

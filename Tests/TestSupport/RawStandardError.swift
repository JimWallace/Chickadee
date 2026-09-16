// Tests/TestSupport/RawStandardError.swift
//
// One raw `write(2)` loop, shared by the two process-level observers in this
// target (`WedgeWatchdog` and `StarvationRecorder`).
//
// Both write from a dedicated OS thread while the cooperative pool may be
// wedged, so neither may go through Swift's buffered stdio: a pinned thread
// can be holding the stdio lock, and an observer that blocks on it produces
// exactly the silence it exists to break. `write(2)` to fd 2 takes no
// userspace lock and needs no allocation beyond the byte array.
//
// Short writes are real on a pipe, so the loop resumes at the offset the
// kernel accepted. A write that fails outright is dropped rather than retried
// forever — the caller is usually mid-abort and the job-level timeout is the
// outer backstop.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum RawStandardError {
    static func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                #if canImport(Glibc)
                return Glibc.write(2, base, buffer.count)
                #elseif canImport(Darwin)
                return Darwin.write(2, base, buffer.count)
                #else
                return -1
                #endif
            }
            if written <= 0 { return }
            offset += written
        }
    }
}

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
// Short writes are real on a pipe, so swift-system's `writeAll` resumes at the
// offset the kernel accepted. A write that fails outright is dropped rather
// than retried forever — the caller is usually mid-abort and the job-level
// timeout is the outer backstop.

import Foundation
import SystemPackage

enum RawStandardError {
    static func write(_ text: String) {
        // `writeAll` is the same `write(2)` loop, without the stdio buffer.
        _ = try? FileDescriptor.standardError.writeAll(text.utf8)
    }
}

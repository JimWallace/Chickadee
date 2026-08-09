// Core/PipeCloseOnExec.swift
//
// One implementation of "make this capture pipe safe to hold while other
// processes are being spawned", for every module that builds a `Pipe` by hand.
//
// It lived in `Sources/Worker/BoundedPipeRead.swift` while the worker was the
// only subprocess-heavy target. It is here now because `Core/ZipArchiver` and
// the server's zip/notebook helpers have the same exposure and cannot import
// the worker — and a second copy is exactly the drift this repo keeps paying
// for.

import Foundation

/// Foundation's `Pipe` does not set `FD_CLOEXEC` (verified on Swift 6.3 /
/// glibc 2.39 and Darwin). Without it, any subprocess spawned concurrently
/// with this run inherits duplicates of these descriptors across its exec,
/// and the read side then never sees EOF until that unrelated process exits.
/// The intended child still receives its ends: `dup2` / spawn file actions
/// clear the flag on the duplicate they install.
///
/// The failure this prevents is the #1139 / #1233 one: while a leaked write
/// end is open the reader cannot reach EOF, so a thread blocked in
/// `readDataToEndOfFile()` stays blocked, and enough of those turn a transient
/// overload into a pool the process never recovers from.
///
/// How reachable that is today was measured rather than assumed, and the
/// answer is narrower than the issue text implies (see
/// `Tests/CoreTests/PipeCloseOnExecTests.swift`): on Swift 6.3 / glibc 2.39
/// both spawners this codebase uses already close inherited descriptors
/// themselves — Foundation's `Process` leaves a child holding only fds 0/1/2,
/// and swift-subprocess `close_range`s everything above stderr. A bare
/// `posix_spawn` still inherits the lot. So this is defence in depth against
/// a spawner that does not do it, not a live bug being patched — but it costs
/// two `fcntl`s, and having every hand-built pipe state the same invariant is
/// what makes an exception visible.
public func setCloseOnExec(_ pipe: Pipe) {
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else { continue }
        _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
    }
}

/// A `Pipe` that already has `FD_CLOEXEC` set — the same one call above, for
/// the common `process.standardError = Pipe()` shape where there is no local
/// name to pass. Using this instead of a bare `Pipe()` is what keeps the
/// no-leaked-write-end invariant reviewable at a glance.
public func closeOnExecPipe() -> Pipe {
    let pipe = Pipe()
    setCloseOnExec(pipe)
    return pipe
}

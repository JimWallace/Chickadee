// Core/ZipProcessSerialization.swift
//
// Process-wide serialization + EFAULT-retry helpers shared by every
// `/usr/bin/zip` / `/usr/bin/unzip` Process invocation in the codebase.
//
// Lives in `Core` (v0.4.178+) so both `chickadee-server` and
// `chickadee-runner` get the same lock + retry without each having
// to roll their own.
//
// Foundation's `Process` has a known race under concurrent invocation
// that surfaces as `NSPOSIXErrorDomain Code=14 "Bad address"` (EFAULT).
// The race spans more than just `posix_spawn` itself — Pipe allocation,
// child fd setup, and spawn all share global state — and reaches across
// the whole Process API surface.  Before this file existed, the lock +
// retry pair lived inside `ZipArchiver.swift` and the sibling zip
// helpers in `TestSetupZipHelpers.swift` issued naked `Process.run()`
// calls that raced against ZipArchiver's lock-protected calls and
// against each other.
//
// Both mitigations now live here and are used by every zip subprocess:
//
//   1. `withZipProcessLock { ... }` serializes the entire zip Process
//      lifecycle (Process + Pipe construction, property setting, spawn,
//      and, for sync paths, the wait and read).  Async paths release
//      inside the continuation closure once the spawn returns; the
//      terminationHandler runs on Foundation's monitoring queue and
//      resumes the continuation independently.
//
//   2. `runProcessWithEFAULTRetry(_:)` retries `Process.run()` once
//      after a 10 ms backoff if it throws `NSPOSIXErrorDomain` /
//      `EFAULT`.  Absorbs the residual race that the lock can't catch
//      (cross-process kernel state, etc.).
//
// Zip operations are infrequent (test setup upload, course bundle
// import, suite save, support-file extraction).  The cost of both
// mitigations is negligible.

import Foundation

/// Process-wide lock held across the **entire** zip subprocess
/// lifecycle.  See file header for rationale.
private let zipProcessLock = NSLock()

/// Serializes `body` against every other zip Process invocation in the
/// codebase.  Use for the synchronous extract / list / extract-entry
/// paths.  Async paths can hold the lock just for the spawn — see
/// `ZipArchiver.swift`'s `runZipProcess`.
public func withZipProcessLock<T>(_ body: () throws -> T) rethrows -> T {
    zipProcessLock.lock()
    defer { zipProcessLock.unlock() }
    return try body()
}

/// Manually lock — paired with `releaseZipProcessLock()`.  Use only for
/// async paths that need to hold the lock from before Process setup
/// through the spawn, then release before awaiting the
/// terminationHandler.  Prefer `withZipProcessLock { ... }` for sync.
public func acquireZipProcessLock() {
    zipProcessLock.lock()
}

/// Pair with `acquireZipProcessLock()`.
public func releaseZipProcessLock() {
    zipProcessLock.unlock()
}

/// The parent environment, read **once** for the lifetime of the process.
///
/// `Process.run()` with a nil `environment` inherits by reading the global
/// environ itself, which makes every zip spawn an unsynchronized *reader* of
/// state that `setenv`/`unsetenv` can reallocate underneath it. That is the
/// same race as the EFAULT one below, in the form the retry cannot help with:
/// when the kernel notices, `run()` throws EFAULT and is retried; when the
/// read walks a reallocated environ in user space instead, the process takes
/// a bad pointer dereference and dies. Seen 2026-08-09 on `api-tests`
/// (`Bad pointer dereference at 0x210`, Thread 5:
/// `_ProcessInfo.environment.getter` ← `Process.run()` ← `listZipEntries`).
///
/// A `let` is initialized exactly once, on first use, under `swift_once` — so
/// every zip subprocess after that gets the snapshot with no further reads.
/// Contents are unchanged from what these spawns inherited before; only the
/// number of racy reads changes, from one per spawn to one per process.
private let zipInheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment

/// A `Process` preconfigured for a zip/unzip spawn.
///
/// Use this instead of a bare `Process()` for every `/usr/bin/zip` and
/// `/usr/bin/unzip` invocation. Setting `environment` non-nil is what stops
/// `run()` from performing the implicit environ read described above — it is
/// not a convenience, and a site that constructs `Process()` directly silently
/// opts back into the crash. `ZipProcessEnvironmentTests` fails on such a site.
public func makeZipProcess() -> Process {
    let process = Process()
    process.environment = zipInheritedEnvironment
    return process
}

/// Calls `proc.run()`, retrying once after a 10 ms backoff if it throws
/// `NSPOSIXErrorDomain` / `EFAULT` (Foundation Process race; see file
/// header).  `proc` must not have been started yet.
///
/// This handles only the *throwing* form of the race. The crashing form is
/// prevented upstream by `makeZipProcess()`, because a segfault cannot be
/// caught and retried.
public func runProcessWithEFAULTRetry(_ proc: Process) throws {
    do {
        try proc.run()
    } catch let error as NSError
        where
        error.domain == NSPOSIXErrorDomain && error.code == Int(EFAULT)
    {
        Thread.sleep(forTimeInterval: 0.01)
        try proc.run()
    }
}

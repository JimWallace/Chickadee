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
//   1. `withZipProcessLock { ... }` serializes the racy window only:
//      Process + Pipe construction, property setting, and the spawn.
//      Everything after the spawn happens outside the lock — the async
//      path (`ZipArchiver.swift`'s `runZipProcess`) releases once the
//      spawn returns and lets the terminationHandler resume the
//      continuation from Foundation's monitoring queue, and the sync
//      helper below (`runZipProcessCapturingStdout`) drains stdout and
//      waits for exit after releasing.  Concurrent zip operations
//      overlap everything but their spawns.
//
//   2. `runProcessWithEFAULTRetry(_:)` retries `Process.run()` once
//      after a 10 ms backoff if it throws `NSPOSIXErrorDomain` /
//      `EFAULT`.  Absorbs the residual race that the lock can't catch
//      (cross-process kernel state, etc.).
//
// The sync paths originally held the lock across the child's whole
// runtime (spawn + drain + wait).  That was tolerable while zip
// subprocesses were rare (test setup upload, course bundle import), but
// the notebook-open and dashboard paths now list/extract zip entries
// per page view, and a whole-runtime lock is a server-wide cap of one
// zip operation at a time — with each contender parking a
// cooperative-pool thread in a blocking `NSLock.lock()`.  The lock's
// scope is therefore the spawn window only, which is all the Foundation
// race ever spanned; the child's runtime was never part of it, as the
// async path demonstrated from the day it was written.

import Foundation

/// Process-wide lock held across zip subprocess **construction + spawn**.
/// See file header for rationale.
private let zipProcessLock = NSLock()

/// Serializes `body` against every other zip Process invocation in the
/// codebase.  `body` must contain only the racy window — Process/Pipe
/// construction through `run()` — never the child's drain or wait.
/// Prefer `runZipProcessCapturingStdout` (sync) or the manual
/// acquire/release pair in `ZipArchiver.swift`'s `runZipProcess` (async)
/// over calling this directly.
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

/// The parent environment, read **once** for the lifetime of the process.
///
/// `Process.run()` with a nil `environment` does not inherit for free: it
/// reads the global environ itself, at spawn time. That makes every zip spawn
/// an unsynchronized *reader* of a structure `setenv`/`unsetenv` reallocates
/// underneath it — and this codebase has writers, since several test suites
/// mutate environment variables and Swift Testing runs them concurrently with
/// everything else.
///
/// It is the same race the EFAULT retry above exists for, in the half that
/// retry cannot reach. When the kernel notices the bad address, `run()` throws
/// EFAULT and the retry absorbs it. When the read instead walks a reallocated
/// environ in user space, the process takes a SIGSEGV and there is nothing to
/// catch — observed on `api-tests` as `Bad pointer dereference at 0x210`, the
/// crashing thread showing `_ProcessInfo.environment.getter` under
/// `Process.run()`.
///
/// `withAsyncEnvLock` cannot help either, for a related reason: its contract
/// asks every reader to take the lock, and a zip spawn is an **undeclared**
/// reader — the read happens inside Foundation, not in any helper anyone
/// thought to wrap.
///
/// A snapshot does not remove the read, it removes the *repetition*: one read
/// per process instead of one per spawn. The contents are exactly what these
/// spawns inherited before, so nothing about their behaviour changes — and
/// nothing on this path consults the environment anyway, since the children
/// are `zip` and `unzip`.
private let zipProcessEnvironment: [String: String] = ProcessInfo.processInfo.environment

/// A `Process` for a zip/unzip spawn, with its environment already set.
///
/// Always construct zip subprocesses through this rather than `Process()`.
/// A bare one has a nil `environment` and so opts back into the implicit
/// read above — silently, with every existing test still green, which is
/// why `ZipProcessEnvironmentTests` fails on one.
public func makeZipProcess() -> Process {
    let process = Process()
    process.environment = zipProcessEnvironment
    return process
}

/// Pair with `acquireZipProcessLock()`.
public func releaseZipProcessLock() {
    zipProcessLock.unlock()
}

/// Calls `proc.run()`, retrying once after a 10 ms backoff if it throws
/// `NSPOSIXErrorDomain` / `EFAULT` (Foundation Process race; see file
/// header).  `proc` must not have been started yet.
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

/// Exit status + captured stdout of a synchronous zip subprocess run.
public struct ZipProcessResult: Sendable {
    public let terminationStatus: Int32
    public let stdout: Data
}

/// Runs a zip/unzip subprocess synchronously: construction + spawn under
/// the process-wide zip lock, stdout drain + exit wait **outside** it.
/// This is the one sync entry point — every synchronous zip subprocess
/// in the codebase goes through here so the narrow lock scope and the
/// EFAULT retry cannot be forgotten at a call site.
///
/// stdout is always drained (an undrained pipe deadlocks the child once
/// it writes past the ~64 KB OS pipe buffer); callers that don't need it
/// just ignore `ZipProcessResult.stdout`.  stderr is sunk to the null
/// device — every former call site discarded it, and the null device
/// can't fill.
public func runZipProcessCapturingStdout(
    executablePath: String,
    arguments: [String],
    workingDirectory: URL? = nil
) throws -> ZipProcessResult {
    let (process, stdoutPipe) = try withZipProcessLock { () throws -> (Process, Pipe) in
        let process = makeZipProcess()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        // CLOEXEC before the spawn: with the lock no longer held across the
        // drain, another zip child can be spawned while this one's stdout is
        // being read — it must not inherit this write end, or the drain
        // below cannot reach EOF until that unrelated child exits (#1233).
        let stdoutPipe = closeOnExecPipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try runProcessWithEFAULTRetry(process)
        return (process, stdoutPipe)
    }
    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ZipProcessResult(terminationStatus: process.terminationStatus, stdout: stdout)
}

// Tests/WorkerTests/Support/ScriptRunnerTestSupport.swift
//
// Shared front door for every WorkerTest that runs a real script through a
// `ScriptRunner`.  It does two things that every such call site wants but used
// to get piecemeal (or not at all):
//
//   1. Throttles the launch through `withSubprocessSlot`, so the suite's ~two
//      dozen concurrent `/bin/sh` / `python3` spawns can't form the
//      fork/posix_spawn storm that flakes these tests under parallel CI load.
//
//   2. Retries *only* the "subprocess never launched" outcome, which
//      `executeScriptLaunch` reports as exit code 2 with the launch-error
//      prefix leading stderr.  That is the transient (a spawn refused under
//      load), never a real grading result.  A genuine regression produces a
//      wrong exit code, captured script output, or `timedOut == true`, none
//      of which match — so nothing real is retried or masked.
//
//      This predicate used to be the bare `-1` exit sentinel with empty
//      output, which conflated a failed launch with a spuriously-fired
//      timeout.  Since the move to swift-subprocess a launch failure is a
//      thrown error mapped to exit 2, and `-1` means only "timed out".
//
// This generalizes the narrow `runRetryingLaunchFailure` added for the two
// env-passthrough tests in #787 to all of the suite's real-script call sites,
// across both `UnsandboxedScriptRunner` and `SandboxedScriptRunner`.

import ChickadeeTestSupport
import Core
import Foundation
import RunnerCore
import Synchronization

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs `script` through `runner` under the shared subprocess-launch throttle,
/// retrying only the "never launched" outcome.
///
/// Drop-in for `await runner.run(...)`: same arguments (with `env` defaulting
/// to empty, matching the `ScriptRunner` convenience overload), same
/// `ScriptOutput` result.
func runScriptRobustly(
    _ runner: some ScriptRunner,
    script: URL,
    workDir: URL,
    timeLimitSeconds: Int,
    env: [String: String] = [:],
    attempts: Int = 5
) async -> ScriptOutput {
    await withSubprocessSlot {
        var output = await runner.run(
            script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: env)
        var remaining = attempts - 1
        while remaining > 0, isLaunchFailure(output) {
            remaining -= 1
            WedgeWatchdog.noteActivity()
            output = await runner.run(
                script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: env)
        }
        return output
    }
}

/// True when `output` is `executeScriptLaunch`'s launch-failure shape: exit 2,
/// no stdout, and a stderr that is exactly the launch-error report. A script
/// that itself exits 2 writes its own stderr (or none), so it can't match.
private func isLaunchFailure(_ output: ScriptOutput) -> Bool {
    output.exitCode == 2 && !output.timedOut && output.stdout.isEmpty
        && output.stderr.hasPrefix("Failed to launch ")
}

/// Builds, launches, and reaps a bare `Process` under the shared
/// subprocess-launch throttle, retrying the *launch* when `Process.run()`
/// throws.  Under parallel CI load `posix_spawn` can transiently fail
/// (EAGAIN), which Foundation surfaces as a misleading "file doesn't exist"
/// CocoaError — the cause of intermittent CI failures in tests that spawn
/// `/usr/bin/env` directly.  Each attempt gets a fresh `Process` from
/// `makeProcess` because a failed `run()` leaves the instance unusable.
/// Returns the exited process; read `terminationStatus` and any attached
/// pipes off it.
func runProcessRobustly(
    attempts: Int = 5,
    makeProcess: @Sendable () throws -> Process
) async throws -> Process {
    try await withSubprocessSlot {
        for _ in 0..<(attempts - 1) {
            let process = try makeProcess()
            if (try? process.run()) != nil {
                await awaitBoundedExit(of: process)
                return process
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let process = try makeProcess()
        try process.run()
        await awaitBoundedExit(of: process)
        return process
    }
}

/// A `Pipe` whose descriptors are CLOEXEC from birth. Always use this for
/// test subprocess I/O: a plain `Pipe()`'s write end is inherited by every
/// concurrently spawned process, and a long-lived inheritor (another test's
/// HTTP server) then keeps EOF from ever reaching the read side — the
/// unbounded-stall ingredient of the #1139/#1233 wedges. The intended child
/// still receives its end; spawn file actions clear the flag on the
/// descriptor they install.
func makeCloexecPipe() -> Pipe {
    closeOnExecPipe()
}

/// Deadline-bounded read-to-EOF for a test subprocess pipe — the drop-in for
/// `readDataToEndOfFile()`, which parks a cooperative-pool thread until an
/// EOF that a leaked write-end duplicate can postpone forever (issue #1233).
/// Returns whatever arrived by the deadline.
func readToEOFBounded(_ pipe: Pipe, timeoutSeconds: TimeInterval = 30) -> Data {
    boundedReadToEOF(
        fromDescriptor: pipe.fileHandleForReading.fileDescriptor,
        deadline: Date().addingTimeInterval(timeoutSeconds)
    )
}

/// Cached Rscript availability probe — one subprocess per test process
/// instead of one per calling test, launched through the shared throttle
/// with CLOEXEC pipes and a bounded exit wait (the previous per-file copies
/// each ran a raw `Process` + `waitUntilExit()` on a pool thread).
func rscriptIsAvailable() async -> Bool {
    if let cached = rscriptAvailabilityCache.withLock({ $0 }) {
        return cached
    }
    let available: Bool
    do {
        let process = try await runProcessRobustly {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["Rscript", "--version"]
            process.standardOutput = makeCloexecPipe()
            process.standardError = makeCloexecPipe()
            return process
        }
        available = process.terminationStatus == 0
    } catch {
        available = false
    }
    rscriptAvailabilityCache.withLock { $0 = available }
    return available
}

private let rscriptAvailabilityCache = Mutex<Bool?>(nil)

/// Suspends until `process` exits, without pinning a cooperative-pool thread
/// the way `waitUntilExit()` does — the pool has ~one thread per core and
/// never grows, so a handful of concurrent blocking waits can freeze the
/// whole test process (the #1233 wedge). Escalates to SIGKILL at the
/// deadline so a hung child bounds the wait instead of inheriting it.
///
/// Same single-shot continuation shape as `executeScriptProcess`: the
/// termination handler is installed after `run()`, so the already-exited
/// race is guarded by `resumed`.
func awaitBoundedExit(of process: Process, timeoutSeconds: TimeInterval = 120) async {
    let killTask = Task {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        guard !Task.isCancelled, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumed = Mutex(false)
        let resumeOnce: @Sendable () -> Void = {
            let alreadyResumed = resumed.withLock { wasResumed in
                let previous = wasResumed
                wasResumed = true
                return previous
            }
            if !alreadyResumed { continuation.resume() }
        }
        process.terminationHandler = { _ in resumeOnce() }
        if !process.isRunning { resumeOnce() }
    }
    killTask.cancel()
    // The handler has fired (or the process was already gone); this reap is
    // immediate and keeps `terminationStatus` reliably readable.
    process.waitUntilExit()
}

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

/// Runs `/usr/bin/env <argv>` through the shared subprocess-launch throttle.
///
/// Replaces `runProcessRobustly`, which built a bare `Process` from a factory
/// and retried the *launch* when `Process.run()` threw. That retry existed for
/// a Foundation defect: under parallel CI load `posix_spawn` transiently fails
/// with EAGAIN, which Foundation surfaces as a misleading "file doesn't exist"
/// CocoaError. `swift-subprocess` does not carry that failure, so the retry has
/// nothing left to absorb and is gone.
///
/// The THROTTLE is not a Foundation defect and stays. Concurrent spawns are a
/// resource question, not a spawner question, and `SubprocessThrottle` holds
/// the suite to four in flight — the property `docs/ci-flakiness.md` Family 5
/// cares about.
func runToolThrottled(
    _ argv: [String],
    workingDirectory: URL? = nil,
    extraEnvironment: [String: String] = [:],
    standardInput: String? = nil
) async throws -> ToolRun {
    try await withSubprocessSlot {
        WedgeWatchdog.noteActivity()
        return try await runTool(
            argv,
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment,
            standardInput: standardInput)
    }
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
        available = try await runToolThrottled(["Rscript", "--version"]).succeeded
    } catch {
        available = false
    }
    rscriptAvailabilityCache.withLock { $0 = available }
    return available
}

private let rscriptAvailabilityCache = Mutex<Bool?>(nil)

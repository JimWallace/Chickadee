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
//   2. Retries *only* the "subprocess never launched" outcome — the `-1` exit
//      sentinel with no output and no timeout.  That outcome is the ambiguous
//      transient (a fork failure under load, or a spuriously-fired timeout);
//      it is never a real result.  A genuine regression produces output (a
//      wrong exit code, captured stdout/stderr, or `timedOut == true`), so it
//      is never retried or masked — only the empty liveness flake is.
//
// This generalizes the narrow `runRetryingLaunchFailure` added for the two
// env-passthrough tests in #787 to all of the suite's real-script call sites,
// across both `UnsandboxedScriptRunner` and `SandboxedScriptRunner`.

import Foundation
import RunnerCore

@testable import chickadee_runner

/// Runs `script` through `runner` under the shared subprocess-launch throttle,
/// retrying only the empty `-1` "never launched" sentinel.
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
        while remaining > 0,
            output.exitCode == -1, !output.timedOut,
            output.stdout.isEmpty, output.stderr.isEmpty
        {
            remaining -= 1
            output = await runner.run(
                script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: env)
        }
        return output
    }
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
                process.waitUntilExit()
                return process
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let process = try makeProcess()
        try process.run()
        process.waitUntilExit()
        return process
    }
}

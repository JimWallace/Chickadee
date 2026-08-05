// Worker/ScriptRunner.swift
//
// Protocol and unsandboxed implementation for running a single test script
// subprocess. `SandboxedScriptRunner` conforms to the same protocol for the
// `--sandbox` path without changing any callers.
//
// Both conformances do the same thing: build a `ScriptLaunch` and hand it to
// `executeScriptLaunch` (ScriptExecution.swift). They differ only in which
// executable ends up at the front of the argument vector.

import Core
import Foundation

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
///
/// `env` is merged on top of an allowlisted subset of the worker's
/// environment (see `mergedScriptEnvironment`); the daemon's secrets are not
/// inherited. Empty dictionary = the allowlisted base only.
protocol ScriptRunner: Sendable {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput
}

extension ScriptRunner {
    /// Convenience overload — call sites without per-run env-var needs can omit `env:`.
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        await run(script: script, workDir: workDir, timeLimitSeconds: timeLimitSeconds, env: [:])
    }
}

/// Phase 1: direct subprocess execution, no sandbox.
struct UnsandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        let invocation = scriptInvocation(for: script)
        let launch = ScriptLaunch(
            executablePath: invocation.executableURL.path,
            arguments: invocation.arguments,
            env: mergedScriptEnvironment(overrides: env)
        )

        return await executeScriptLaunch(
            launch,
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch script"
        )
    }
}

// MARK: - Environment

/// Environment keys a test script is allowed to inherit from the worker
/// process. Everything else — notably `RUNNER_SHARED_SECRET`, DB URLs, and
/// any other worker credential present in the daemon's environment — is
/// withheld so a student submission cannot read it back out via stdout/stderr
/// and forge worker API requests. Per-job values (`CHICKADEE_*`, seed inputs)
/// arrive through `overrides`, which always win.
private let scriptEnvironmentAllowlistKeys: Set<String> = [
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "LANG",
    "TERM", "PWD",
]

/// Key prefixes whose every member is safe to inherit (locale + the per-job
/// Chickadee namespace).
private let scriptEnvironmentAllowlistPrefixes: [String] = ["LC_", "CHICKADEE_"]

private func isAllowlistedScriptEnvironmentKey(_ key: String) -> Bool {
    if scriptEnvironmentAllowlistKeys.contains(key) { return true }
    return scriptEnvironmentAllowlistPrefixes.contains { key.hasPrefix($0) }
}

/// Build the environment for a test-script subprocess: an allowlisted subset
/// of the worker's environment, plus `overrides` (which win on collision).
///
/// The worker daemon runs with secrets in its environment (`RUNNER_SHARED_SECRET`,
/// database URLs, OIDC client secrets); inheriting the full environment would
/// hand those to arbitrary student code. We therefore start from an allowlist
/// rather than `ProcessInfo.processInfo.environment` wholesale.
func mergedScriptEnvironment(overrides: [String: String]) -> [String: String] {
    var base: [String: String] = [:]
    for (key, value) in ProcessInfo.processInfo.environment
    where isAllowlistedScriptEnvironmentKey(key) {
        base[key] = value
    }
    for (key, value) in overrides {
        base[key] = value
    }
    return base
}

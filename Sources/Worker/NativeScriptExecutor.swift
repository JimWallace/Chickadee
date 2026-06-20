// Worker/NativeScriptExecutor.swift
//
// The worker's conformance to RunnerCore's `ScriptExecutor` — the substrate
// the shared `executeSuites` loop drives. It wraps the existing `ScriptRunner`
// (sandboxed or not), the per-job test-setup working directory, and the
// per-job environment overrides (e.g. the personalization seed), translating
// RunnerCore's bare-filename, Foundation-free interface into the worker's
// `URL`-based subprocess calls.
//
// This is the *first* conformance: the browser runner's `BrowserScriptExecutor`
// (Pyodide via JavaScriptKit) is a drop-in second one. The protocol was born
// exercised by a real caller, never a floating speculative interface.

import Core
import Foundation

/// Runs scripts as subprocesses (via `ScriptRunner`) under a fixed working
/// directory, merging a fixed set of environment overrides into every run.
///
/// `Sendable` because the shared `executeSuites` loop is a nonisolated async
/// function and the executor is handed to it from the `WorkerDaemon` actor —
/// all stored properties are themselves `Sendable`.
struct NativeScriptExecutor: ScriptExecutor, Sendable {
    /// The sandbox boundary — `UnsandboxedScriptRunner` or `SandboxedScriptRunner`.
    let runner: any ScriptRunner
    /// The prepared test-setup directory; scripts are resolved relative to it
    /// and it is the subprocess working directory.
    let workDir: URL
    /// Environment overrides merged into every script run (e.g. the
    /// `CHICKADEE_ASSIGNMENT_SEED`). Empty = inherit the parent env verbatim.
    let env: [String: String]
    /// Per-script execution time-limit overrides (script name → seconds). A
    /// script listed here runs with its own limit; everything else uses the
    /// `timeLimitSeconds` that the shared `executeSuites` loop passes (the
    /// assignment default). This is resolved here, in the executor, rather than
    /// in RunnerCore's `executeSuites` — that loop is the wasm-pinned shared
    /// implementation and must keep receiving only the assignment default.
    let overrides: [String: Int]

    init(
        runner: any ScriptRunner, workDir: URL,
        env: [String: String] = [:], overrides: [String: Int] = [:]
    ) {
        self.runner = runner
        self.workDir = workDir
        self.env = env
        self.overrides = overrides
    }

    func scriptExists(_ name: String) async -> Bool {
        FileManager.default.fileExists(atPath: workDir.appendingPathComponent(name).path)
    }

    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput {
        await runner.run(
            script: workDir.appendingPathComponent(script),
            workDir: workDir,
            timeLimitSeconds: resolveTimeLimit(
                script: script, default: timeLimitSeconds, overrides: overrides),
            env: env
        )
    }
}

/// Resolves the effective per-test time limit for `script`: its override when
/// present, otherwise the assignment `default`. Pure (no I/O) so the resolution
/// rule can be unit-tested without a real subprocess.
func resolveTimeLimit(script: String, default defaultLimit: Int, overrides: [String: Int]) -> Int {
    overrides[script] ?? defaultLimit
}

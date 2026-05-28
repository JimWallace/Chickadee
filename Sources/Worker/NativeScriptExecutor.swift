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

    func scriptExists(_ name: String) async -> Bool {
        FileManager.default.fileExists(atPath: workDir.appendingPathComponent(name).path)
    }

    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput {
        await runner.run(
            script: workDir.appendingPathComponent(script),
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            env: env
        )
    }
}

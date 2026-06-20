// Tests/WorkerTests/NativeScriptExecutorTimeLimitTests.swift
//
// Unit tests for the per-test time-limit resolution in NativeScriptExecutor:
// the pure `resolveTimeLimit` helper and the executor's `run`, which must apply
// a per-script override when present and otherwise fall back to the assignment
// default the shared `executeSuites` loop passes.

import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

// Records the timeLimitSeconds each script.run was invoked with, so the
// executor's resolution can be asserted without launching a real subprocess.
private actor RecordingScriptRunner: ScriptRunner {
    private(set) var limitByScript: [String: Int] = [:]

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        limitByScript[script.lastPathComponent] = timeLimitSeconds
        return ScriptOutput(exitCode: 0, stdout: "", stderr: "", executionTimeMs: 0, timedOut: false)
    }

    func limit(for script: String) -> Int? { limitByScript[script] }
}

@Suite struct NativeScriptExecutorTimeLimitTests {

    // MARK: - Pure resolution helper

    @Test func resolveTimeLimitPrefersOverride() {
        #expect(resolveTimeLimit(script: "a.py", default: 10, overrides: ["a.py": 3]) == 3)
    }

    @Test func resolveTimeLimitFallsBackToDefaultForUnlistedScript() {
        #expect(resolveTimeLimit(script: "b.py", default: 10, overrides: ["a.py": 3]) == 10)
    }

    @Test func resolveTimeLimitFallsBackWithNoOverrides() {
        #expect(resolveTimeLimit(script: "a.py", default: 7, overrides: [:]) == 7)
    }

    // MARK: - End-to-end through run()

    @Test func runUsesOverrideForListedScript() async {
        let recorder = RecordingScriptRunner()
        let executor = NativeScriptExecutor(
            runner: recorder,
            workDir: URL(fileURLWithPath: "/tmp"),
            overrides: ["a.py": 3])
        _ = await executor.run(script: "a.py", timeLimitSeconds: 10)
        #expect(await recorder.limit(for: "a.py") == 3)
    }

    @Test func runUsesDefaultForUnlistedScript() async {
        let recorder = RecordingScriptRunner()
        let executor = NativeScriptExecutor(
            runner: recorder,
            workDir: URL(fileURLWithPath: "/tmp"),
            overrides: ["a.py": 3])
        _ = await executor.run(script: "b.py", timeLimitSeconds: 10)
        #expect(await recorder.limit(for: "b.py") == 10)
    }
}

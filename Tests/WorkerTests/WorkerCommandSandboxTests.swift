// Tests/WorkerTests/WorkerCommandSandboxTests.swift
//
// `--sandbox` must select the sandboxed runner. The mutation sweep of
// 2026-09-22 (#1574) swapped the two branches of the choice and the whole
// suite stayed green, so a runner started with `--sandbox` could have graded
// student code unsandboxed and nothing would have failed. The choice and the
// label the startup log reports now come from one function, pinned here.

import Testing

@testable import chickadee_runner

@Suite struct WorkerCommandSandboxTests {

    @Test func theSandboxFlagSelectsTheSandboxedRunner() {
        let choice = WorkerCommand.scriptRunner(sandboxed: true)
        #expect(choice.runner is SandboxedScriptRunner)
        #expect(choice.label == "sandboxed")
    }

    @Test func withoutTheFlagTheRunnerIsUnsandboxed() {
        let choice = WorkerCommand.scriptRunner(sandboxed: false)
        #expect(choice.runner is UnsandboxedScriptRunner)
        #expect(choice.label == "unsandboxed")
    }
}

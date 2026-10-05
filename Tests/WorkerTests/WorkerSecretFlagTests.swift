// Tests/WorkerTests/WorkerSecretFlagTests.swift
//
// `--worker-secret` puts the runner secret in the runner's command line, which
// every test script can read from /proc, also inside the sandbox. A runner
// started with both flags must refuse to start; without `--sandbox` the flag
// still works but warns, until the next minor release removes it.

import ChickadeeTestSupport
import Testing

@testable import chickadee_runner

@Suite struct WorkerSecretFlagTests {

    @Test func withoutTheFlagNothingIsReported() {
        #expect(WorkerCommand.workerSecretFlagUse(flagSet: false, sandboxed: true) == .notUsed)
        #expect(WorkerCommand.workerSecretFlagUse(flagSet: false, sandboxed: false) == .notUsed)
    }

    @Test func theFlagIsRefusedWithTheSandbox() throws {
        guard case .refused(let reason) = WorkerCommand.workerSecretFlagUse(flagSet: true, sandboxed: true)
        else {
            throw IssueRecorded("--worker-secret with --sandbox was not refused")
        }
        #expect(reason.hasPrefix("Error:"))
        #expect(reason.contains("--sandbox"))
        #expect(reason.contains("RUNNER_SHARED_SECRET"))
    }

    @Test func theFlagWarnsWithoutTheSandbox() throws {
        guard case .deprecated(let warning) = WorkerCommand.workerSecretFlagUse(flagSet: true, sandboxed: false)
        else {
            throw IssueRecorded("--worker-secret without --sandbox did not warn")
        }
        #expect(warning.hasPrefix("Warning:"))
        #expect(warning.contains("deprecated"))
        #expect(warning.contains("RUNNER_SHARED_SECRET"))
    }
}

// Tests/WorkerTests/WorkerStartupFailureTests.swift
//
// The runner's startup refusals. The mutation sweep of 2026-09-29 deleted the
// stderr write in front of each `throw ExitCode.failure` and nothing failed,
// so a runner could refuse to start without telling the operator why.

import ArgumentParser
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct WorkerStartupFailureTests {

    @Test func startupFailureReportsTheMessageAndReturnsTheFailureExit() async {
        let capture = RunnerLogCapture()
        let exit = RunnerLogCapture.$current.withValue(capture) {
            WorkerCommand.startupFailure("Error: missing runner secret.\n")
        }
        #expect(exit == ExitCode.failure)
        #expect(capture.capturedLines == ["Error: missing runner secret."])
    }
}

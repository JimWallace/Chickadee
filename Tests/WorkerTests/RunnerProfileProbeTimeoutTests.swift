// Tests/WorkerTests/RunnerProfileProbeTimeoutTests.swift
//
// A capability probe that runs out of time is logged, with the command and
// the limit, before the detector gives up on it. The mutation sweep of
// 2026-10-13 (#2535) deleted that log call (`:285 RemoveSideEffects`) and
// nothing failed. The log line is the only trace of a probe that timed out:
// the profile just lacks the language, and `RunnerLanguageGate` then leaves
// every job that needs it in the queue with no error (see
// RunnerProfileDetectorGapTests).
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(1))) struct RunnerProfileProbeTimeoutTests {

    @Test func aProbeThatRunsOutOfTimeIsLoggedAndYieldsNothing() async throws {
        let capture = RunnerLogCapture()
        let result = await RunnerLogCapture.$current.withValue(capture) {
            await RunnerProfileDetector(discoveryEnabled: true)
                .runProbe(command: "sleep", arguments: ["30"], timeoutSeconds: 0.2)
        }
        #expect(result == nil)

        let line = try #require(capture.capturedLines.first)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(payload["event"] as? String == "local_execution_error")
        #expect(payload["error_type"] as? String == "capability_detection_timeout")
        #expect(payload["error_message_summary"] as? String == "sleep 30")
        #expect(payload["timeout_seconds"] as? Double == 0.2)
    }
}

// Tests/WorkerTests/ReporterStaleClaimTests.swift
//
// The server refuses a result for a claim it no longer counts (HTTP 410,
// `ResultClaimCheck`). The reporter must surface that as `claimSuperseded`
// after one attempt, so the runner drops the job instead of retrying or
// reporting a failure, and it must echo the job's claim token.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized, .timeLimit(.minutes(3))) struct ReporterStaleClaimTests {

    private func reporter() -> Reporter {
        let policy = RunnerRetryPolicy(enabled: true, maxAttempts: 5, baseDelayMs: 0, maxDelayMs: 0)
        return Reporter(
            apiBaseURL: testURL("https://server.test"), workerID: "test-worker", workerSecret: "test-secret",
            heartbeatRetryPolicy: policy, resultUploadRetryPolicy: policy, session: .mocked())
    }

    private func report(claimToken: String?) -> WorkerExecutionReport {
        let collection = TestOutcomeCollection(
            submissionID: "sub_stale", testSetupID: "ts_1", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [], totalTests: 0, passCount: 0, failCount: 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test/0.0.1", timestamp: Date())
        return WorkerExecutionReport(collection: collection, diagnostics: nil, claimToken: claimToken)
    }

    @Test func a410IsClaimSupersededAfterOneAttempt() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(410))
            var refusal: ReporterError?
            do {
                try await reporter().report(report(claimToken: "123"))
            } catch {
                refusal = error as? ReporterError
            }
            guard case .claimSuperseded = refusal else {
                throw IssueRecorded("expected claimSuperseded, got \(String(describing: refusal))")
            }
            #expect(MockURLProtocol.capturedRequests.count == 1, "a stale claim is not retried")
        }
    }

    @Test func theReportEchoesTheClaimToken() async throws {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            try await reporter().report(report(claimToken: "1762700000123456"))
            let body = try #require(MockURLProtocol.capturedBodies.first)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            #expect(try decoder.decode(WorkerExecutionReport.self, from: body).claimToken == "1762700000123456")
        }
    }

    @Test func aJobDecodesItsClaimTokenAndAnOlderServersJobHasNone() throws {
        let job = Job(
            submissionID: "s", testSetupID: "t", attemptNumber: 1, submissionURL: testURL("https://x.test/s"),
            testSetupURL: testURL("https://x.test/t"), manifest: TestProperties(language: nil), language: nil,
            claimToken: "42")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(job)
        #expect(try decoder.decode(Job.self, from: data).claimToken == "42")

        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var object = try #require(parsed)
        object.removeValue(forKey: "claimToken")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(Job.self, from: older).claimToken == nil)
    }
}

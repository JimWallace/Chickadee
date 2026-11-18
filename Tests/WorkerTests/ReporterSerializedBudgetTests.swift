// Tests/WorkerTests/ReporterSerializedBudgetTests.swift
//
// The reporter enforces the collection's serialized budget (#1157) before it
// posts a result: a report over `defaultSerializedBudgetBytes` goes out with
// its long outputs truncated, and one within it goes out exactly as encoded.
// Core's truncation is pinned in `TestOutcomeCollectionTruncationTests`; this
// suite pins the reporter's decision to call it, whose `>` survived the
// 2026-11-10 mutation sweep (#2970) because no test posted an oversized
// report.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized, .timeLimit(.minutes(3))) struct ReporterSerializedBudgetTests {

    private static let budget = TestOutcomeCollection.defaultSerializedBudgetBytes

    private func reporter() -> Reporter {
        let policy = RunnerRetryPolicy(enabled: true, maxAttempts: 1, baseDelayMs: 0, maxDelayMs: 0)
        return Reporter(
            apiBaseURL: testURL("https://server.test"), workerID: "test-worker", workerSecret: "test-secret",
            heartbeatRetryPolicy: policy, resultUploadRetryPolicy: policy, session: .mocked())
    }

    /// A report whose outcomes each carry `longResultBytes` of output.
    private func report(outcomeCount: Int, longResultBytes: Int) -> WorkerExecutionReport {
        let outcomes = (0..<outcomeCount).map { index in
            TestOutcome(
                testName: "test_\(index)", testClass: nil, tier: .pub, status: .fail,
                shortResult: "failed", longResult: String(repeating: "x", count: longResultBytes),
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        }
        let collection = TestOutcomeCollection(
            submissionID: "sub_budget", testSetupID: "ts_1", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomeCount, passCount: 0,
            failCount: outcomeCount, errorCount: 0, timeoutCount: 0, executionTimeMs: 1,
            runnerVersion: "test/0.0.1", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        return WorkerExecutionReport(collection: collection, diagnostics: nil)
    }

    private func postAndCapture(_ report: WorkerExecutionReport) async throws -> Data {
        try await withMockURLProtocolLock {
            MockURLProtocol.reset()
            MockURLProtocol.enqueue(.status(200))
            try await reporter().report(report)
            return try #require(MockURLProtocol.capturedBodies.first)
        }
    }

    private func decode(_ body: Data) throws -> WorkerExecutionReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkerExecutionReport.self, from: body)
    }

    @Test func aReportOverTheBudgetIsPostedTruncatedToFitIt() async throws {
        // Four outcomes of 2 MB each: 8 MB of output against a 6 MB budget.
        let oversized = report(outcomeCount: 4, longResultBytes: 2 * 1024 * 1024)
        let body = try await postAndCapture(oversized)

        #expect(body.count <= Self.budget + 64 * 1024, "the posted body must fit the budget plus the envelope")
        let posted = try decode(body).collection
        #expect(posted.outcomes.count == 4, "truncation never drops an outcome")
        for outcome in posted.outcomes {
            let longResult = try #require(outcome.longResult)
            #expect(longResult.hasSuffix(TestOutcomeCollection.truncationMarker))
            #expect(outcome.status == .fail, "statuses are never altered")
        }
    }

    @Test func aReportWithinTheBudgetIsPostedUntruncated() async throws {
        let small = report(outcomeCount: 3, longResultBytes: 1_000)
        let body = try await postAndCapture(small)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Same length, not same bytes: JSONEncoder does not fix the order of
        // keys, so two encodings of one value can differ byte for byte.
        #expect(body.count == (try encoder.encode(small)).count)
        let posted = try decode(body).collection
        #expect(posted.outcomes.allSatisfy { $0.longResult == String(repeating: "x", count: 1_000) })
        #expect(posted.warnings == small.collection.warnings, "nothing was cut, so no truncation warning")
    }
}

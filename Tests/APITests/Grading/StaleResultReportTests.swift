// Tests/APITests/Grading/StaleResultReportTests.swift
//
// Result ingest accepts a runner's report only for the claim that runner
// still holds. A forced "Retest all" re-queues rows that runners are grading
// under the old manifest; the report each of those runners still posts is
// refused, so it can neither complete the re-queued row with an old-suite
// grade nor land a second result beside the retest's own.

import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(2))) final class StaleResultReportTests {
    let app: Application
    private let workerSecret = "test-worker-secret-stale"
    private let resultsPath = "/api/v1/worker/results"

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-stale-report")
        await app.workerSecretStore.setRuntimeOverride(workerSecret)
    }

    // MARK: - Fixtures

    private func pendingSubmission(_ id: String, setupID: String) async throws {
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            try await APITestSetup(
                id: setupID, manifest: TestManifests.workerOnePythonSuite,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: try await app.testCourseID()
            ).save(on: app.db)
        }
        try await APISubmission(
            id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1, status: SubmissionStatus.pending.rawValue, kind: APISubmission.Kind.student
        ).save(on: app.db)
    }

    private func claim(_ id: String, as workerID: String) async throws -> APISubmission {
        try #require(try await WorkerJobClaim.claimSubmission(id: id, workerID: workerID, db: app.db))
    }

    private func report(
        submissionID: String, setupID: String, claimToken: String?
    ) -> WorkerExecutionReport {
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 10, runnerVersion: "runner/1.0", timestamp: Date(timeIntervalSince1970: 0))
        return WorkerExecutionReport(collection: collection, diagnostics: nil, claimToken: claimToken)
    }

    /// Posts `report` signed as `workerID` and returns the response status.
    /// A nil `workerID` sends no `X-Worker-Id`, as the visual-regression
    /// seed does.
    private func post(_ report: WorkerExecutionReport, as workerID: String?) async throws -> HTTPResponseStatus {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = ByteBuffer(data: try encoder.encode(report))
        var status = HTTPResponseStatus.imATeapot
        try await app.asyncTest(
            .POST, resultsPath,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: self.resultsPath, body: body,
                    workerSecret: self.workerSecret, workerID: workerID ?? "")
                if workerID == nil { req.headers.remove(name: WorkerHMACSigning.Header.workerID) }
                req.body = body
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func reload(_ id: String) async throws -> APISubmission {
        try #require(try await APISubmission.find(id, on: app.db))
    }

    private func resultCount(_ id: String) async throws -> Int {
        try await APIResult.query(on: app.db).filter(\.$submissionID == id).count()
    }

    // MARK: - Tests

    /// The reported bug: runner A grades under the old manifest, the
    /// instructor forces a retest, and A's report lands before any runner
    /// re-claims the row. The row stays pending for the retest.
    @Test func aReportAfterAForcedRetestIsRefused() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_a", setupID: "setup_stale_a")
            _ = try await claim("stale_a", as: "runner-a")

            try await retestAllSubmissionsForSetup(
                setupID: "setup_stale_a", triggeredBy: nil, on: app.db, force: true)

            let status = try await post(
                report(submissionID: "stale_a", setupID: "setup_stale_a", claimToken: nil), as: "runner-a")
            #expect(status == .gone)
            #expect(try await reload("stale_a").status == SubmissionStatus.pending.rawValue)
            #expect(try await resultCount("stale_a") == 0)
        }
    }

    /// The stale report lands after runner B re-claimed the row: it neither
    /// completes B's claim nor adds a result row.
    @Test func aReportForAClaimAnotherRunnerHoldsIsRefused() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_b", setupID: "setup_stale_b")
            _ = try await claim("stale_b", as: "runner-a")
            try await retestAllSubmissionsForSetup(
                setupID: "setup_stale_b", triggeredBy: nil, on: app.db, force: true)
            _ = try await claim("stale_b", as: "runner-b")

            let status = try await post(
                report(submissionID: "stale_b", setupID: "setup_stale_b", claimToken: nil), as: "runner-a")
            #expect(status == .gone)
            let row = try await reload("stale_b")
            #expect(row.status == SubmissionStatus.assigned.rawValue)
            #expect(row.workerID == "runner-b")
            #expect(try await resultCount("stale_b") == 0)
        }
    }

    /// The same runner re-claimed the row: only the claim token tells its
    /// old report from its new one.
    @Test func aReportForTheSameRunnersEarlierClaimIsRefused() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_c", setupID: "setup_stale_c")
            let first = try await claim("stale_c", as: "runner-a")
            let firstToken = try #require(first.assignedAt.map(WorkerClaimToken.token(assignedAt:)))
            try await retestAllSubmissionsForSetup(
                setupID: "setup_stale_c", triggeredBy: nil, on: app.db, force: true)
            let second = try await claim("stale_c", as: "runner-a")
            let secondToken = try #require(second.assignedAt.map(WorkerClaimToken.token(assignedAt:)))
            #expect(firstToken != secondToken)

            let stale = try await post(
                report(submissionID: "stale_c", setupID: "setup_stale_c", claimToken: firstToken), as: "runner-a")
            #expect(stale == .gone)
            #expect(try await reload("stale_c").status == SubmissionStatus.assigned.rawValue)
            #expect(try await resultCount("stale_c") == 0)

            let current = try await post(
                report(submissionID: "stale_c", setupID: "setup_stale_c", claimToken: secondToken), as: "runner-a")
            #expect(current == .ok)
            #expect(try await reload("stale_c").status == SubmissionStatus.complete.rawValue)
            #expect(try await resultCount("stale_c") == 1)
        }
    }

    /// The holder's own report completes the row, and a replay of it (a
    /// response lost in transit) is still accepted, as before.
    @Test func theHoldersReportAndItsReplayAreAccepted() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_d", setupID: "setup_stale_d")
            let claimed = try await claim("stale_d", as: "runner-a")
            let token = try #require(claimed.assignedAt.map(WorkerClaimToken.token(assignedAt:)))
            let body = report(submissionID: "stale_d", setupID: "setup_stale_d", claimToken: token)

            #expect(try await post(body, as: "runner-a") == .ok)
            #expect(try await reload("stale_d").status == SubmissionStatus.complete.rawValue)
            #expect(try await post(body, as: "runner-a") == .ok)
        }
    }

    /// A row that was never claimed, or that no longer exists, takes no report.
    @Test func aReportForAnUnclaimedOrMissingRowIsRefused() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_e", setupID: "setup_stale_e")
            #expect(
                try await post(
                    report(submissionID: "stale_e", setupID: "setup_stale_e", claimToken: nil), as: "runner-a")
                    == .gone)
            #expect(try await reload("stale_e").status == SubmissionStatus.pending.rawValue)
            #expect(
                try await post(
                    report(submissionID: "no_such_row", setupID: "setup_stale_e", claimToken: nil), as: "runner-a")
                    == .gone)
            #expect(try await resultCount("no_such_row") == 0)
        }
    }

    /// A report with no runner id is checked by its claim token alone, so a
    /// row marked claimed with no runner (the visual-regression seed) takes
    /// the report that names its claim, and only that one.
    @Test func aReportWithNoRunnerIDNeedsTheMatchingToken() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_g", setupID: "setup_stale_g")
            try await APISubmission.query(on: app.db).filter(\.$id == "stale_g")
                .set(\.$status, to: SubmissionStatus.assigned.rawValue)
                .set(\.$assignedAt, to: Date())
                .update()
            let assignedAt = try #require(try await reload("stale_g").assignedAt)
            let token = WorkerClaimToken.token(assignedAt: assignedAt)

            #expect(
                try await post(report(submissionID: "stale_g", setupID: "setup_stale_g", claimToken: nil), as: nil)
                    == .gone)
            #expect(
                try await post(report(submissionID: "stale_g", setupID: "setup_stale_g", claimToken: "1"), as: nil)
                    == .gone)
            #expect(try await resultCount("stale_g") == 0)
            #expect(
                try await post(report(submissionID: "stale_g", setupID: "setup_stale_g", claimToken: token), as: nil)
                    == .ok)
            #expect(try await reload("stale_g").status == SubmissionStatus.complete.rawValue)
        }
    }

    /// The stuck-submission reaper re-queues a row the same way: the slow
    /// runner's eventual report is refused.
    @Test func aReportAfterTheReaperRequeuedTheRowIsRefused() async throws {
        try await withApp(app) { _ in
            try await pendingSubmission("stale_f", setupID: "setup_stale_f")
            _ = try await claim("stale_f", as: "runner-a")
            try await APISubmission.query(on: app.db).filter(\.$id == "stale_f")
                .set(\.$assignedAt, to: Date().addingTimeInterval(-3600)).update()
            let reaped = try await reapStuckAssignedSubmissions(on: app.db, logger: app.logger)
            #expect(reaped >= 1)

            let status = try await post(
                report(submissionID: "stale_f", setupID: "setup_stale_f", claimToken: nil), as: "runner-a")
            #expect(status == .gone)
            #expect(try await reload("stale_f").status == SubmissionStatus.pending.rawValue)
        }
    }
}

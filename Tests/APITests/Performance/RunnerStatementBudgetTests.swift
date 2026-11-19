// Tests/APITests/Performance/RunnerStatementBudgetTests.swift
//
// The statements of the two runner requests that do work: a claim, and the
// result report that follows it. `StatementBudgetTests` holds the pages and
// the idle poll; these two need a pending job, so they get their own fixture.
// The counting is the same (`StatementCounter.swift`): what the request sends
// on `req.db`, not the session or metrics work production adds.
//
// A count above its budget fails. A count below it prints a note: lower the
// budget then, so the count cannot creep back up.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct RunnerStatementBudgetTests {

    /// The statements each request may send. Raise one only with the reason
    /// in the pull request.
    enum Budget {
        static let claim = 16
        static let resultReport = 17
    }

    private static let workerSecret = "runner-statement-budget-secret"
    /// The one runner that claims and reports: result ingest accepts a report
    /// only from the runner that holds the claim (`ResultClaimCheck`).
    private static let workerID = "runner-budget"
    private static let workerManifest = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    /// One open worker-graded assignment and a pending submission on it.
    private func withPendingJob(
        _ body: (Application, StatementRecorder, _ submissionID: String, _ setupID: String) async throws -> Void
    ) async throws {
        try await withTestApp(prefix: "chickadee-runner-statements") { app in
            let recorder = StatementRecorder()
            app.middleware.use(StatementCountingMiddleware(recorder: recorder), at: .beginning)
            await app.workerSecretStore.setRuntimeOverride(Self.workerSecret)
            let course = try await makeTestCourse(on: app, code: "RUNSTMT")
            let courseID = try course.requireID()
            let setupID = "setup_runner_budget"
            try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: Self.workerManifest)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
            let student = try await makeTestStudent(on: app, username: "runner_budget_student")
            let submissionID = "sub_runner_budget"
            try await makeTestSubmission(
                on: app, id: submissionID, setupID: setupID, userID: try student.requireID(), status: "pending")
            try await body(app, recorder, submissionID, setupID)
        }
    }

    private func poll(on app: Application) async throws -> TestResponse {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: Self.workerID, hostname: "runner-budget.local", runnerVersion: "budget/1.0",
            maxConcurrentJobs: 1, activeJobs: 0, profile: nil)
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        let headers = workerHMACHeaders(
            method: .POST, path: path, body: body, workerSecret: Self.workerSecret, workerID: Self.workerID)
        return try await app.asyncSendRequest(.POST, path, headers: headers, body: body)
    }

    private func report(submissionID: String, setupID: String, on app: Application) async throws -> TestResponse {
        let outcome = TestOutcome(
            testName: "test.sh", testClass: nil, tier: .pub, status: .pass, shortResult: "passed",
            longResult: nil, executionTimeMs: 5, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: true)
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 1, failCount: 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 5, runnerVersion: "budget/1.0",
            timestamp: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = ByteBuffer(data: try encoder.encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
        let path = "/api/v1/worker/results"
        let headers = workerHMACHeaders(
            method: .POST, path: path, body: body, workerSecret: Self.workerSecret, workerID: Self.workerID)
        return try await app.asyncSendRequest(.POST, path, headers: headers, body: body)
    }

    @Test func aClaimStaysWithinItsBudget() async throws {
        try await withPendingJob { app, recorder, _, _ in
            recorder.arm()
            let response = try await poll(on: app)
            let statements = recorder.disarm()
            #expect(response.status == .ok)
            expectWithin(statements, Budget.claim, "a claim")
        }
    }

    @Test func aResultReportStaysWithinItsBudget() async throws {
        try await withPendingJob { app, recorder, submissionID, setupID in
            let claimed = try await poll(on: app)
            #expect(claimed.status == .ok)
            recorder.arm()
            let response = try await report(submissionID: submissionID, setupID: setupID, on: app)
            let statements = recorder.disarm()
            #expect(response.status == .ok)
            expectWithin(statements, Budget.resultReport, "a result report")
        }
    }

    private func expectWithin(
        _ statements: [String], _ budget: Int, _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            statements.count <= budget,
            """
            \(what): \(statements.count) statements, budget \(budget). Find the added statement:
            \(statements.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """,
            sourceLocation: sourceLocation)
        if statements.count < budget {
            print(
                "note: \(what) sends \(statements.count) statements; lower its budget in RunnerStatementBudgetTests from \(budget) to \(statements.count)."
            )
        }
    }
}

// Tests/APITests/Grading/HotPathStatementBudgetTests.swift
//
// The number of SQL statements each hot request sends, pinned. The recent
// performance work cut these one at a time (#2907, #2916, #2923); nothing
// stopped a later change from adding them back, one `find` at a time. Each
// budget is the exact count, so a change in either direction shows in the
// diff: raise a budget only with the reason in the commit, and lower it when
// a change saves a statement.
//
// The counts include the middleware's statements (the session lookup, the
// nonce insert), because the request pays for them too.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct HotPathStatementBudgetTests {

    /// The statements each request may send.
    enum Budget {
        static let idleRunnerPoll = 0
        static let claim = 0
        static let resultReport = 0
        static let statusPoll = 0
        static let studentDashboard = 0
        static let submissionPage = 0
    }

    private static let workerSecret = "statement-budget-secret"
    private static let workerManifest = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    /// A course in `.auto` mode with one open worker-graded assignment, and a
    /// signed-in student enrolled in it.
    struct Fixture {
        let app: Application
        let setupID: String
        let studentID: UUID
        let cookie: String
    }

    private func withFixture(_ body: (Fixture, StatementLog) async throws -> Void) async throws {
        try await withTestApp(prefix: "chickadee-statement-budget") { app in
            await app.workerSecretStore.setRuntimeOverride(Self.workerSecret)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setupID = "setup_budget"
            try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: Self.workerManifest)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
            let cookie = try await loginAsStudent("budget_student", on: app)
            try await enrollInTestCourse(username: "budget_student", role: .student, on: app)
            let found = try await APIUser.query(on: app.db).filter(\.$username == "budget_student").first()
            let student = try #require(found)

            let log = StatementLog()
            app.countStatements(into: log)
            try await body(
                Fixture(app: app, setupID: setupID, studentID: try student.requireID(), cookie: cookie), log)
        }
    }

    // MARK: - Runner

    private func poll(_ fixture: Fixture, workerID: String = "budget-runner") async throws -> HTTPStatus {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: workerID, hostname: "\(workerID).local", runnerVersion: "budget/1.0",
            maxConcurrentJobs: 1, activeJobs: 0, profile: nil)
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        var status = HTTPStatus.internalServerError
        try await fixture.app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST, path: path, body: body, workerSecret: Self.workerSecret)
                req.headers.contentType = .json
                req.body = body
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func idleRunnerPoll() async throws {
        try await withFixture { fixture, log in
            #expect(try await poll(fixture) == .noContent)
            expectBudget(log, Budget.idleRunnerPoll, "the idle runner poll")
        }
    }

    @Test func claim() async throws {
        try await withFixture { fixture, log in
            try await makeTestSubmission(
                on: fixture.app, id: "sub_budget_claim", setupID: fixture.setupID, userID: fixture.studentID,
                status: "pending")
            #expect(try await poll(fixture) == .ok)
            expectBudget(log, Budget.claim, "a claim")
        }
    }

    @Test func resultReport() async throws {
        try await withFixture { fixture, log in
            try await makeTestSubmission(
                on: fixture.app, id: "sub_budget_report", setupID: fixture.setupID, userID: fixture.studentID,
                status: "pending")
            #expect(try await poll(fixture) == .ok)
            log.reset()

            let outcome = TestOutcome(
                testName: "test.sh", testClass: nil, tier: .pub, status: .pass, shortResult: "passed",
                longResult: nil, executionTimeMs: 5, memoryUsageBytes: nil, attemptNumber: 1,
                isFirstPassSuccess: true)
            let collection = TestOutcomeCollection(
                submissionID: "sub_budget_report", testSetupID: fixture.setupID, attemptNumber: 1,
                buildStatus: .passed, compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 1,
                failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 5, runnerVersion: "budget/1.0",
                timestamp: Date(timeIntervalSince1970: 0))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = ByteBuffer(
                data: try encoder.encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
            let path = "/api/v1/worker/results"
            try await fixture.app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHMACHeaders(
                        method: .POST, path: path, body: body, workerSecret: Self.workerSecret)
                    req.body = body
                },
                afterResponse: { res in #expect(res.status == .ok) })
            expectBudget(log, Budget.resultReport, "a result report")
        }
    }

    // MARK: - Student

    private func get(_ path: String, _ fixture: Fixture) async throws {
        try await fixture.app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: fixture.cookie) },
            afterResponse: { res in #expect(res.status == .ok, "GET \(path)") })
    }

    @Test func statusPoll() async throws {
        try await withFixture { fixture, log in
            try await makeTestSubmission(
                on: fixture.app, id: "sub_budget_status", setupID: fixture.setupID, userID: fixture.studentID,
                status: "pending")
            try await get("/api/v1/submissions/sub_budget_status", fixture)
            expectBudget(log, Budget.statusPoll, "the status poll")
        }
    }

    @Test func studentDashboard() async throws {
        try await withFixture { fixture, log in
            try await makeTestSubmission(
                on: fixture.app, id: "sub_budget_dashboard", setupID: fixture.setupID,
                userID: fixture.studentID)
            try await get("/", fixture)
            expectBudget(log, Budget.studentDashboard, "the student dashboard")
        }
    }

    @Test func submissionPage() async throws {
        try await withFixture { fixture, log in
            try await makeTestSubmission(
                on: fixture.app, id: "sub_budget_page", setupID: fixture.setupID, userID: fixture.studentID)
            try await makeTestResult(on: fixture.app, submissionID: "sub_budget_page")
            try await get("/submissions/sub_budget_page", fixture)
            expectBudget(log, Budget.submissionPage, "the submission page")
        }
    }

    // MARK: - Check

    private func expectBudget(
        _ log: StatementLog, _ budget: Int, _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let statements = log.all
        #expect(
            statements.count == budget,
            """
            \(what) sent \(statements.count) SQL statements; its budget is \(budget). \
            A rise needs its reason in the commit; a fall lowers the budget. Statements:
            \(statements.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """,
            sourceLocation: sourceLocation)
    }
}

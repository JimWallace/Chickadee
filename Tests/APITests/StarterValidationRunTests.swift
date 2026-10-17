// Tests/APITests/StarterValidationRunTests.swift
//
// The starter run (notebook views NB8): each validation also grades the
// assignment notebook. The run is queued after the solution run, with the
// same submitter, and a later save replaces a run that no runner holds. A
// runner claims it after the solution run. Its result never moves the
// assignment's `validationStatus`, so the gate that blocks opening is
// unchanged. MCP `get_suite` returns its outcomes.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) final class StarterValidationRunTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-starterrun")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    private let workerSecret = "starter-run-worker-secret"

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"test_a.py","points":2},\
        {"tier":"public","script":"test_b.py","points":0}],"timeLimitSeconds":10,"makefile":null}
        """

    private let solution = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    private struct Fixture {
        let setupID: String
        let submitterID: UUID
        let assignment: APIAssignment
    }

    private func fixture(_ tag: String) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "SR\(tag)")
        let courseID = try course.requireID()
        let user = try await makeTestUser(on: app, username: "tester", role: "instructor")
        let userID = try user.requireID()
        try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)
        let setupID = "srsetup_\(tag)"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Starter Lab \(tag)")
        return Fixture(setupID: setupID, submitterID: userID, assignment: assignment)
    }

    @discardableResult
    private func enqueue(_ fx: Fixture) async throws -> String {
        try await enqueueRunnerValidationSubmission(
            context: makeTestRequest(on: app), setupID: fx.setupID, solutionNotebookData: Data(solution.utf8),
            submitterUserID: fx.submitterID)
    }

    private func starterRuns(_ setupID: String) async throws -> [APISubmission] {
        try await APISubmission.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.starterValidation)
            .all()
    }

    @Test func aValidationQueuesOneStarterRunWithTheSameSubmitter() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("a")
            try await enqueue(fx)
            let first = try await starterRuns(fx.setupID)
            #expect(first.count == 1)
            #expect(first.first?.userID == fx.submitterID)
            let starterPath = try #require(first.first?.zipPath)
            #expect(FileManager.default.fileExists(atPath: starterPath))

            // A second save replaces the run that no runner holds yet.
            try await enqueue(fx)
            let second = try await starterRuns(fx.setupID)
            #expect(second.count == 1)
            #expect(second.first?.id != first.first?.id)
            #expect(!FileManager.default.fileExists(atPath: starterPath))
        }
    }

    @Test func aSetupWithNoAssignmentNotebookQueuesNoStarterRun() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("b")
            let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
            if let path = setup.notebookPath { try FileManager.default.removeItem(atPath: path) }
            try await enqueue(fx)
            #expect(try await starterRuns(fx.setupID).isEmpty)
        }
    }

    @Test func aRunnerClaimsTheSolutionRunFirst() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("c")
            let solutionID = try await enqueue(fx)
            let starterID = try #require(try await starterRuns(fx.setupID).first?.id)
            #expect(try await claim() == solutionID)
            #expect(try await claim() == starterID)
        }
    }

    @Test func aStarterResultLeavesTheGateAndReachesTheOutlineAndGetSuite() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("d")
            try await enqueue(fx)
            let starterID = try #require(try await starterRuns(fx.setupID).first?.id)
            try await postResult(submissionID: starterID, setupID: fx.setupID, passing: ["test_a", "test_b"])

            let assignment = try #require(try await APIAssignment.find(fx.assignment.id, on: app.db))
            #expect(assignment.validationStatus == nil)

            let run = try #require(try await StarterValidationRun.latest(setupID: fx.setupID, on: app.db))
            #expect(run.submissionID == starterID)

            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: fx.assignment.publicID),
                ToolContext(request: makeTestRequest(on: app), subject: "tester", grantedScopes: [.read]))
            let starter = try #require(suite.starterRun)
            #expect(starter.didNotRun == nil)
            #expect(starter.outcomes.map(\.testName) == ["test_a", "test_b"])
            #expect(starter.outcomes.map(\.status) == ["pass", "pass"])
        }
    }

    // MARK: - Helpers

    private func claim() async throws -> String? {
        let path = "/api/v1/worker/request"
        let body = try ByteBuffer(
            data: JSONEncoder().encode(
                WorkerActivityPayload(
                    workerID: "sr-worker", hostname: "sr.local", runnerVersion: "runner-tests/1.0",
                    maxConcurrentJobs: 2, activeJobs: 0, profile: nil)))
        var claimed: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                if res.status == .ok { claimed = try res.content.decode(Job.self).submissionID }
            })
        return claimed
    }

    private func postResult(submissionID: String, setupID: String, passing: [String]) async throws {
        let outcomes = passing.map { name in
            TestOutcome(
                testName: name, testClass: nil, tier: .pub, status: .pass, shortResult: "passed", longResult: nil,
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
        }
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count, passCount: outcomes.count,
            failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 5, runnerVersion: "runner-tests/1.0",
            timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try ByteBuffer(
            data: encoder.encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
        let path = "/api/v1/worker/results"
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in #expect(res.status == .ok) })
    }
}

/// Whether a starter run ran, and the issues it raises in the outline. Pure.
@Suite struct StarterRunOutlineTests {

    private func run(_ statuses: [(String, TestStatus)], build: BuildStatus = .passed) -> TestOutcomeCollection {
        let outcomes = statuses.map { name, status in
            TestOutcome(
                testName: name, testClass: nil, tier: .pub, status: status,
                shortResult: status == .error ? "SyntaxError: invalid syntax" : "ok", longResult: nil,
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        }
        return TestOutcomeCollection(
            submissionID: "sub_x", testSetupID: "setup_x", attemptNumber: 1, buildStatus: build,
            compilerOutput: build == .failed ? "make: *** [all] Error 1\nmore" : nil, outcomes: outcomes,
            totalTests: outcomes.count, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 1, runnerVersion: "runner-tests/1.0", timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test func aStarterThatDoesNotBuildOrErrorsEverywhereDidNotRun() {
        #expect(
            StarterValidationRun.failure(of: run([("test_a", .error)], build: .failed)) == "make: *** [all] Error 1")
        #expect(StarterValidationRun.failure(of: run([])) == "no test ran")
        #expect(
            StarterValidationRun.failure(of: run([("test_a", .error), ("test_b", .error)]))
                == "SyntaxError: invalid syntax")
        #expect(StarterValidationRun.failure(of: run([("test_a", .error), ("test_b", .fail)])) == nil)
    }

    private let manifest = TestProperties(
        testSuites: [
            TestSuiteEntry(tier: .pub, script: "test_a.py", points: 2),
            TestSuiteEntry(tier: .pub, script: "test_b.py", points: 0),
            TestSuiteEntry(tier: .pub, script: "test_c.py", points: 1),
        ], language: .python)

    private func outline(starter: TestOutcomeCollection?) -> InstructorSuiteOutline {
        InstructorSuiteOutlineBuilder(
            manifest: manifest,
            notebook: NotebookDefinitionScan(definitions: [], sections: [], codeCellIndices: []),
            scriptSources: [:], validationStatus: "failed",
            solutionRun: run([("test_a", .pass), ("test_b", .pass), ("test_c", .fail)]),
            starterRun: starter
        ).build()
    }

    @Test func aTestWorthPointsThatPassesOnTheStarterIsAnIssue() {
        let built = outline(starter: run([("test_a", .pass), ("test_b", .pass), ("test_c", .pass)]))
        let issues = built.validation.issues.map { "\($0.itemID) \($0.kind)" }
        // A test worth no points is not flagged, and a test that fails on the
        // solution is flagged for that alone.
        #expect(issues == ["test_c.py failsOnSolution", "test_a.py passesOnStarter"])
        #expect(built.unlinked.map { $0.starter?.result } == ["pass", "pass", "pass"])
        #expect(built.validation.starterRunAt == Date(timeIntervalSince1970: 0))
        #expect(built.validation.starterError == nil)
    }

    @Test func aStarterThatDidNotRunFlagsNothing() {
        let built = outline(starter: run([("test_a", .error), ("test_b", .error), ("test_c", .error)]))
        #expect(built.validation.issues.map(\.kind) == ["failsOnSolution"])
        #expect(built.validation.starterError == "SyntaxError: invalid syntax")
        #expect(built.unlinked.allSatisfy { $0.starter == nil })
    }

    @Test func beforeAStarterRunNothingChanges() {
        let built = outline(starter: nil)
        #expect(built.validation.issues.map(\.kind) == ["failsOnSolution"])
        #expect(built.validation.starterRunAt == nil)
    }
}

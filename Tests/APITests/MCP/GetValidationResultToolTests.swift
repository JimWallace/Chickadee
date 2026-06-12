// Tests for GetValidationResultTool: it surfaces the per-test outcomes of an
// assignment's reference-solution validation run, resolves the validation
// submission the same way get_solution does (linked, else most-recent
// validation), and never reaches a student submission. Backed by a real test
// database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetValidationResultToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    /// Course + enrolled instructor "tester" + setup + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_val", courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_val", courseID: courseID, title: "Lab")
    }

    private func testerID(on app: Application) async throws -> UUID {
        try await #require(
            APIUser.query(on: app.db).filter(\.$username == "tester").first()
        ).requireID()
    }

    private func outcome(
        _ name: String, _ status: TestStatus, tier: TestTier = .pub, short: String,
        long: String? = nil
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: tier, status: status, shortResult: short,
            longResult: long, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: status == .pass)
    }

    private func collectionJSON(
        submissionID: String, outcomes: [TestOutcome], buildStatus: BuildStatus = .passed
    ) throws -> String {
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "setup_val", attemptNumber: 1,
            buildStatus: buildStatus, compilerOutput: buildStatus == .failed ? "boom" : nil,
            outcomes: outcomes, totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count,
            errorCount: outcomes.filter { $0.status == .error }.count,
            timeoutCount: outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: 5, runnerVersion: "shell-runner/1.0", timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(collection)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func run(
        _ app: Application, publicID: String
    ) async throws
        -> GetValidationResultTool.Output
    {
        try await GetValidationResultTool().execute(
            GetValidationResultTool.Input(assignmentPublicID: publicID), context(app))
    }

    // MARK: - Happy path

    @Test func returnsPerTestOutcomesForLinkedValidation() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            try await makeTestSubmission(
                on: app, id: "sub_val", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_val",
                collectionJSON: collectionJSON(
                    submissionID: "sub_val",
                    outcomes: [
                        outcome("df is loaded", .pass, short: "ok"),
                        outcome(
                            "two charts", .fail, tier: .secret,
                            short: "too few figures", long: "expected at least: 2\ngot: 0"),
                    ]))
            assignment.validationSubmissionID = "sub_val"
            assignment.validationStatus = "failed"
            try await assignment.save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)

            #expect(output.validationStatus == "failed")
            #expect(output.buildStatus == "passed")
            #expect(output.outcomes.count == 2)
            #expect(output.counts?.pass == 1)
            #expect(output.counts?.fail == 1)
            #expect(output.ranAt != nil)
            let failing = try #require(output.outcomes.first { $0.status == "fail" })
            #expect(failing.tier == "secret")  // secret-tier failures are visible
            #expect(failing.longResult?.contains("got: 0") == true)
        }
    }

    @Test func resolvesMostRecentValidationWhenNoLink() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // No validationSubmissionID link; a validation submission + result
            // exists for the setup and should be resolved by the fallback.
            try await makeTestSubmission(
                on: app, id: "sub_fallback", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_fallback",
                collectionJSON: collectionJSON(
                    submissionID: "sub_fallback",
                    outcomes: [outcome("only check", .pass, short: "ok")]))
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.validationStatus == "passed")
            #expect(output.outcomes.count == 1)
            #expect(output.outcomes.first?.testName == "only check")
        }
    }

    // MARK: - Guardrails

    @Test func neverSurfacesStudentSubmissions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // A graded STUDENT submission + result exists, but no validation run.
            // The tool must not resolve or surface the student's result.
            try await makeTestSubmission(
                on: app, id: "sub_student", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.student)
            try await makeTestResult(
                on: app, submissionID: "sub_student",
                collectionJSON: collectionJSON(
                    submissionID: "sub_student",
                    outcomes: [outcome("student secret", .pass, short: "leaked?")]))
            assignment.validationStatus = "pending"
            try await assignment.save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.outcomes.isEmpty)
            #expect(output.counts == nil)
            #expect(output.validationStatus == "pending")
        }
    }

    @Test func emptyWhenNoResultYet() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            try await assignment.save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.outcomes.isEmpty)
            #expect(output.validationStatus == "none")  // no validationStatus set yet
            #expect(output.ranAt == nil)
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(app, publicID: "zzzzzz")
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_val", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_val", courseID: courseID, title: "Lab")
            assignment.validationStatus = "failed"
            try await assignment.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(app, publicID: assignment.publicID)
            }
        }
    }
}

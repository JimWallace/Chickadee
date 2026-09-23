// get_validation_result must still report the primary run when the variant
// batch cannot be read. In production the least-privilege MCP role had no
// grant on `validation_variants` (the grants file is applied by hand, and was
// applied before the table existed), so the variant query threw and every call
// failed, hiding the outcomes an agent needs to fix a suite. Dropping the table
// reproduces the same failure on the test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetValidationResultVariantFallbackTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    /// Course + enrolled instructor "tester" + setup + assignment.
    private func fixture(on app: Application) async throws -> (APIAssignment, UUID) {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_val", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_val", courseID: courseID, title: "Lab")
        return (assignment, try tester.requireID())
    }

    private func collectionJSON(submissionID: String) throws -> String {
        let outcome = TestOutcome(
            testName: "human marker", testClass: nil, tier: .secret, status: .fail,
            shortResult: "wrong sample", longResult: nil, executionTimeMs: 1,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "setup_val", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [outcome], totalTests: 1,
            passCount: 0, failCount: 1, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 5, runnerVersion: "shell-runner/1.0", timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode(collection), encoding: .utf8))
    }

    private func run(
        _ app: Application, publicID: String
    ) async throws
        -> GetValidationResultTool.Output
    {
        try await GetValidationResultTool().execute(
            GetValidationResultTool.Input(assignmentPublicID: publicID), context(app))
    }

    @Test func reportsOutcomesWhenTheVariantBatchCannotBeRead() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, testerID) = try await fixture(on: app)
            try await makeTestSubmission(
                on: app, id: "sub_val", setupID: "setup_val", userID: testerID,
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_val",
                collectionJSON: collectionJSON(submissionID: "sub_val"))
            assignment.validationSubmissionID = "sub_val"
            assignment.validationStatus = "failed"
            try await assignment.save(on: app.db)
            try await app.db.schema(ValidationVariant.schema).delete()

            let output = try await run(app, publicID: assignment.publicID)

            #expect(output.outcomes.map(\.testName) == ["human marker"])
            #expect(output.counts?.fail == 1)
            #expect(output.variants.isEmpty)
            let warning = try #require(output.warnings.last)
            #expect(warning.contains("variant batch could not be read"))
        }
    }

    @Test func reportsTheWarningWhenThereIsNoResultYet() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            try await app.db.schema(ValidationVariant.schema).delete()

            let output = try await run(app, publicID: assignment.publicID)

            #expect(output.outcomes.isEmpty)
            #expect(output.variants.isEmpty)
            #expect(output.warnings.count == 1)
        }
    }

    @Test func readsTheVariantBatchWithoutAWarningWhenTheTableIsReadable() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)

            let output = try await run(app, publicID: assignment.publicID)

            #expect(output.warnings.isEmpty)
        }
    }

    @Test func describesANonPostgresErrorAsIs() {
        struct Failure: Error, CustomStringConvertible {
            var description: String { "disk full" }
        }
        #expect(DatabaseErrorDetail.describe(Failure()) == "disk full")
    }
}

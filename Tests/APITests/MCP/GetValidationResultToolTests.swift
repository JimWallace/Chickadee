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
        submissionID: String, outcomes: [TestOutcome], buildStatus: BuildStatus = .passed,
        runnerVersion: String = "shell-runner/1.0"
    ) throws -> String {
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "setup_val", attemptNumber: 1,
            buildStatus: buildStatus, compilerOutput: buildStatus == .failed ? "boom" : nil,
            outcomes: outcomes, totalTests: outcomes.count,
            passCount: outcomes.filter { $0.status == .pass }.count,
            failCount: outcomes.filter { $0.status == .fail }.count,
            errorCount: outcomes.filter { $0.status == .error }.count,
            timeoutCount: outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: 5, runnerVersion: runnerVersion, timestamp: Date())
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

    /// Runner attribution: which runner produced the result, and the build it
    /// was running. Without these, a failure caused by a runner lagging behind
    /// what the suite needs is indistinguishable from a content bug — which is
    /// exactly how a mixed fleet burned a day of debugging.
    @Test func reportsWhichRunnerProducedTheResultAndItsVersion() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let submission = try await makeTestSubmission(
                on: app, id: "sub_val", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.validation)
            submission.workerID = "runner-abc123"
            try await submission.save(on: app.db)
            try await makeTestResult(
                on: app, submissionID: "sub_val",
                collectionJSON: collectionJSON(
                    submissionID: "sub_val",
                    outcomes: [outcome("df is loaded", .pass, short: "ok")],
                    runnerVersion: "0.4.632"))
            assignment.validationSubmissionID = "sub_val"
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)

            #expect(output.runnerID == "runner-abc123")
            // The version carried on the result itself — the build that actually
            // produced these outcomes, not whatever that runner is running now.
            #expect(output.runnerVersion == "0.4.632")
        }
    }

    /// A pending / no-result assignment reports no attribution rather than
    /// inventing one.
    @Test func reportsNoRunnerAttributionWhenThereIsNoResult() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.runnerID == nil)
            #expect(output.runnerVersion == nil)
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

    // MARK: - Multi-variant batch

    @Test func reportsTheVariantBatchWithFailingOutcomesOnly() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)

            // A failed variant with a stored run: one passing and one failing
            // outcome, of which only the failing one should surface.
            try await makeTestSubmission(
                on: app, id: "sub_var0", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.validation)
            try await makeTestResult(
                on: app, submissionID: "sub_var0",
                collectionJSON: collectionJSON(
                    submissionID: "sub_var0",
                    outcomes: [
                        outcome("loads", .pass, short: "ok"),
                        outcome(
                            "mean is close", .fail, short: "off by 4.2",
                            long: "expected 121.3, got 125.5"),
                    ]))
            let failed = ValidationVariant(
                testSetupID: "setup_val", variantIndex: 0,
                seedHex: DatasetDiagnostics.preflightSeed(0), submissionID: "sub_var0")
            failed.status = ValidationVariant.Status.failed
            try await failed.save(on: app.db)

            // A still-running variant: reported by status alone.
            try await makeTestSubmission(
                on: app, id: "sub_var1", setupID: "setup_val", userID: testerID(on: app),
                kind: APISubmission.Kind.validation, status: "pending")
            try await ValidationVariant(
                testSetupID: "setup_val", variantIndex: 1,
                seedHex: DatasetDiagnostics.preflightSeed(1), submissionID: "sub_var1"
            ).save(on: app.db)

            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.variants.count == 2)

            let first = try #require(output.variants.first)
            #expect(first.variantIndex == 0)
            #expect(first.seedHex == DatasetDiagnostics.preflightSeed(0))
            #expect(first.status == "failed")
            #expect(first.buildStatus == "passed")
            #expect(first.failingOutcomes.map(\.testName) == ["mean is close"])
            #expect(first.failingOutcomes.first?.shortResult == "off by 4.2")

            let second = try #require(output.variants.last)
            #expect(second.variantIndex == 1)
            #expect(second.status == "pending")
            #expect(second.failingOutcomes.isEmpty)
        }
    }

    @Test func variantsAreEmptyWhenNoBatchExists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await run(app, publicID: assignment.publicID)
            #expect(output.variants.isEmpty)
        }
    }
}

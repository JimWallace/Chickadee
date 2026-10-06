// Tests for RunValidationTool: it queues a fresh validation run of the current
// solution, optionally for one online runner, and changes no content. Backed by
// a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct RunValidationToolTests {
    private func context(_ app: Application, scopes: Set<ContentScope> = [.write]) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: scopes)
    }

    /// Course + enrolled instructor "tester" + setup + an open assignment whose
    /// solution has passed validation once.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_run", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_run", courseID: courseID, title: "Lab")
        try await makeTestSubmission(
            on: app, id: "sub_first_run", setupID: "setup_run", userID: tester.requireID(),
            kind: APISubmission.Kind.validation, status: "complete")
        assignment.validationSubmissionID = "sub_first_run"
        assignment.validationStatus = "passed"
        try await assignment.save(on: app.db)
        return assignment
    }

    private func run(
        _ assignment: APIAssignment, runnerID: String?, _ app: Application
    ) async throws -> RunValidationTool.Output {
        try await RunValidationTool().execute(
            RunValidationTool.Input(
                assignmentPublicID: assignment.publicID, runnerID: runnerID, timeoutSeconds: 1),
            context(app))
    }

    @Test func queuesAFreshRunForTheNamedRunner() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await app.workerActivityStore.markActive(workerID: "Starling", hostname: "starling-runner")

            let output = try await run(assignment, runnerID: "Starling", app)

            #expect(output.targetRunnerID == "Starling")
            #expect(output.validationStatus == "pending")
            #expect(output.timedOut)
            #expect(output.runnerID == nil)
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            let runID = try #require(reloaded.validationSubmissionID)
            #expect(runID != "sub_first_run")
            let queued = try #require(try await APISubmission.find(runID, on: app.db))
            #expect(queued.kind == APISubmission.Kind.validation)
            #expect(queued.status == SubmissionStatus.pending.rawValue)
            #expect(queued.targetRunnerID == "Starling")
        }
    }

    @Test func queuesARunForAnyRunnerWithoutAName() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await run(assignment, runnerID: nil, app)

            #expect(output.targetRunnerID == nil)
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            let runID = try #require(reloaded.validationSubmissionID)
            let queued = try #require(try await APISubmission.find(runID, on: app.db))
            #expect(queued.targetRunnerID == nil)
        }
    }

    /// A misspelled or offline runner fails at once, naming the runners that
    /// are online, instead of delaying the run by the fallback time.
    @Test func refusesARunnerThatIsNotOnline() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await app.workerActivityStore.markActive(workerID: "Sparrow", hostname: "sparrow-runner")
            await app.workerActivityStore.markActive(
                workerID: "Starling", hostname: "starling-runner",
                at: Date().addingTimeInterval(-(RunValidationTool.onlineRunnerSeconds + 60)))

            await #expect(
                throws: MCPToolError.invalidArguments(
                    detail: "Runner \"Starling\" has not polled in the last 120 seconds. Online runners: Sparrow.")
            ) {
                _ = try await run(assignment, runnerID: "Starling", app)
            }
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.validationSubmissionID == "sub_first_run")
        }
    }

    /// A re-run changes no content, so an open assignment stays open.
    @Test func leavesAnOpenAssignmentOpen() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.isOpen)
            _ = try await run(assignment, runnerID: nil, app)
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.isOpen)
        }
    }

    @Test func refusesAnAssignmentWithNoSolution() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            assignment.validationSubmissionID = nil
            try await assignment.save(on: app.db)
            try await APISubmission.query(on: app.db).delete()

            await #expect(throws: MCPToolError.self) {
                _ = try await run(assignment, runnerID: nil, app)
            }
        }
    }

    @Test func requiresTheWriteScope() {
        #expect(RunValidationTool.requiredScopes == [.write])
    }
}

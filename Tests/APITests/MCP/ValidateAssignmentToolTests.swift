// Tests for ValidateAssignmentTool + the shared watchValidation logic that backs
// both it and the SSE progress stream. Backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct ValidateAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    /// Course + enrolled instructor "tester" + setup + assignment. Returns the
    /// assignment so the test can set its validation state.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_val", courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_val", courseID: courseID, title: "Lab")
    }

    /// Collects emitted progress messages across the watch's child task.
    private actor MessageLog {
        private(set) var messages: [String] = []
        func add(_ m: String) { messages.append(m) }
    }

    // MARK: - watchValidation

    @Test func watchReturnsImmediatelyWhenAlreadyTerminal() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            let log = MessageLog()
            let outcome = try await watchValidation(
                on: app.db, assignmentPublicID: assignment.publicID,
                pollInterval: .milliseconds(50),
                deadline: ContinuousClock().now.advanced(by: .seconds(5)),
                emit: { _, m in await log.add(m) })

            #expect(outcome.validationStatus == "passed")
            #expect(outcome.timedOut == false)
            let messages = await log.messages
            #expect(messages.contains { $0.contains("passed") })
        }
    }

    @Test func watchTimesOutWhileStillPending() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            assignment.validationStatus = "pending"
            try await assignment.save(on: app.db)

            let outcome = try await watchValidation(
                on: app.db, assignmentPublicID: assignment.publicID,
                pollInterval: .milliseconds(50),
                deadline: ContinuousClock().now.advanced(by: .milliseconds(150)),
                emit: { _, _ in })

            #expect(outcome.timedOut)
            #expect(outcome.validationStatus == "pending")
        }
    }

    @Test func watchObservesRunningThenPassedTransition() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())
            // A pending validation submission the watch will observe transitioning.
            try await makeTestSubmission(
                on: app, id: "sub_val", setupID: "setup_val", userID: tester.requireID(),
                kind: APISubmission.Kind.validation, status: "pending")
            assignment.validationStatus = "pending"
            assignment.validationSubmissionID = "sub_val"
            try await assignment.save(on: app.db)

            let log = MessageLog()
            async let watched = watchValidation(
                on: app.db, assignmentPublicID: assignment.publicID,
                pollInterval: .milliseconds(40),
                deadline: ContinuousClock().now.advanced(by: .seconds(10)),
                emit: { _, m in await log.add(m) })

            // Drive the transitions the runner would normally cause.
            try await Task.sleep(for: .milliseconds(120))
            let sub = try #require(try await APISubmission.find("sub_val", on: app.db))
            sub.status = "assigned"
            try await sub.save(on: app.db)
            try await Task.sleep(for: .milliseconds(120))
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            let outcome = try await watched
            #expect(outcome.validationStatus == "passed")
            #expect(outcome.timedOut == false)
            let messages = await log.messages
            #expect(messages.contains { $0.contains("Running") })
            #expect(messages.contains { $0.contains("passed") })
        }
    }

    // MARK: - ValidateAssignmentTool

    @Test func toolReturnsTerminalStatus() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            assignment.validationStatus = "failed"
            try await assignment.save(on: app.db)

            let output = try await ValidateAssignmentTool().execute(
                ValidateAssignmentTool.Input(
                    assignmentPublicID: assignment.publicID, timeoutSeconds: 5),
                context(app))
            #expect(output.validationStatus == "failed")
            #expect(output.timedOut == false)
        }
    }

    @Test func toolTimesOutWhilePending() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            assignment.validationStatus = "pending"
            try await assignment.save(on: app.db)

            let output = try await ValidateAssignmentTool().execute(
                ValidateAssignmentTool.Input(
                    assignmentPublicID: assignment.publicID, timeoutSeconds: 1),
                context(app))
            #expect(output.timedOut)
        }
    }

    @Test func toolUnknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await ValidateAssignmentTool().execute(
                    ValidateAssignmentTool.Input(assignmentPublicID: "zzzzzz", timeoutSeconds: 1),
                    context(app))
            }
        }
    }

    @Test func toolDeniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_val", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_val", courseID: courseID, title: "Lab")
            assignment.validationStatus = "passed"
            try await assignment.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                _ = try await ValidateAssignmentTool().execute(
                    ValidateAssignmentTool.Input(
                        assignmentPublicID: assignment.publicID, timeoutSeconds: 1),
                    context(app))
            }
        }
    }
}

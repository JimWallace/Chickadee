// Tests for UpdateAssignmentTool (open/close), backed by a real test database.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private func enrolledAssignment(
        on app: Application, dueAt: Date? = nil, validationStatus: String? = nil, isOpen: Bool = false
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_u", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_u", courseID: courseID, title: "Tasks", dueAt: dueAt,
            isOpen: isOpen)
        if let validationStatus {
            assignment.validationStatus = validationStatus
            try await assignment.save(on: app.db)
        }
        return assignment
    }

    @Test func opensAndPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledAssignment(on: app, isOpen: false)
            let output = try await UpdateAssignmentTool().execute(
                UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, isOpen: true),
                context(app))
            #expect(output.isOpen)
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == true)
        }
    }

    @Test func openingPastDueSetsOverride() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledAssignment(
                on: app, dueAt: Date().addingTimeInterval(-3600), isOpen: false)
            _ = try await UpdateAssignmentTool().execute(
                UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, isOpen: true),
                context(app))
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.deadlineOverrideActive == true)
        }
    }

    @Test func closesAndPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledAssignment(on: app, isOpen: true)
            let output = try await UpdateAssignmentTool().execute(
                UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, isOpen: false),
                context(app))
            #expect(output.isOpen == false)
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == false)
        }
    }

    @Test func refusesOpenUntilValidationPasses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await enrolledAssignment(on: app, validationStatus: "pending")
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTool().execute(
                    UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, isOpen: true),
                    context(app))
            }
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == false)
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester")
            try await makeTestSetup(on: app, id: "setup_u", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_u", courseID: courseID, title: "Tasks", isOpen: false)

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTool().execute(
                    UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, isOpen: true),
                    context(app))
            }
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.isOpen == false)
        }
    }
}

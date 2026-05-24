// Tests for UpdateAssignmentTitleTool, backed by a real test database.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateAssignmentTitleToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    @Test func updatesTitleTrimmedAndPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS241", name: "Foundations")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_old", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_old", courseID: courseID, title: "Old Title")
            let publicID = assignment.publicID

            let output = try await UpdateAssignmentTitleTool().execute(
                UpdateAssignmentTitleTool.Input(assignmentPublicID: publicID, title: "  New Title  "),
                context(app))
            #expect(output.title == "New Title")

            let reloaded = try await assignmentByPublicID(publicID, on: app.db)
            #expect(reloaded?.title == "New Title")
        }
    }

    @Test func rejectsEmptyTitle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS245", name: "Logic")
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_keep", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_keep", courseID: courseID, title: "Keep")

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTitleTool().execute(
                    UpdateAssignmentTitleTool.Input(assignmentPublicID: assignment.publicID, title: "   "),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolledInAssignmentCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS241", name: "Foundations")
            let courseID = try course.requireID()
            // "tester" exists but is NOT enrolled in the assignment's course.
            _ = try await makeTestUser(on: app, username: "tester")
            try await makeTestSetup(on: app, id: "setup_ns", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_ns", courseID: courseID, title: "Old Title")

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTitleTool().execute(
                    UpdateAssignmentTitleTool.Input(assignmentPublicID: assignment.publicID, title: "New"),
                    context(app))
            }
            // The title must be unchanged after a denied write.
            let reloaded = try await assignmentByPublicID(assignment.publicID, on: app.db)
            #expect(reloaded?.title == "Old Title")
        }
    }

    @Test func allowsAdminSubjectWithoutEnrollment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS241", name: "Foundations")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "admin")
            try await makeTestSetup(on: app, id: "setup_adm", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_adm", courseID: courseID, title: "Old Title")

            let output = try await UpdateAssignmentTitleTool().execute(
                UpdateAssignmentTitleTool.Input(assignmentPublicID: assignment.publicID, title: "New Title"),
                context(app))
            #expect(output.title == "New Title")
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTitleTool().execute(
                    UpdateAssignmentTitleTool.Input(assignmentPublicID: "zzzzzz", title: "X"),
                    context(app))
            }
        }
    }
}

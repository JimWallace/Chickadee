// Tests for GetAssignmentTool, backed by a real test database.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct GetAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    @Test func returnsDetailForEnrolledSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_g", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_g", courseID: courseID, title: "Tasks", isOpen: false)

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.publicID == assignment.publicID)
            #expect(output.title == "Tasks")
            #expect(output.courseCode == "CS246")
            #expect(output.isOpen == false)
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_g", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_g", courseID: courseID, title: "Tasks")

            await #expect(throws: MCPToolError.self) {
                _ = try await GetAssignmentTool().execute(
                    GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.self) {
                _ = try await GetAssignmentTool().execute(
                    GetAssignmentTool.Input(assignmentPublicID: "zzzzzz"), context(app))
            }
        }
    }
}

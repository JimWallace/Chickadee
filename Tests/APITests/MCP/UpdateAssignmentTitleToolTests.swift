// Tests for UpdateAssignmentTitleTool, backed by a real test database.

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
            let course = APICourse(code: "CS241", name: "Foundations")
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let assignment = APIAssignment(testSetupID: "s1", title: "Old Title", courseID: courseID)
            try await assignment.save(on: app.db)
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
            let course = APICourse(code: "CS245", name: "Logic")
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let assignment = APIAssignment(testSetupID: "s1", title: "Keep", courseID: courseID)
            try await assignment.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTitleTool().execute(
                    UpdateAssignmentTitleTool.Input(assignmentPublicID: assignment.publicID, title: "   "),
                    context(app))
            }
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

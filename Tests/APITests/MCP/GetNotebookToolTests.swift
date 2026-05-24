// Tests for GetNotebookTool (read an assignment's notebook), backed by a real
// test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetNotebookToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    private let twoCellNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Lab"]},
        {"cell_type":"code","metadata":{},"source":["x = 1\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// Course + enrolled instructor "tester" + setup (with the default empty
    /// notebook) + assignment.  Returns the assignment.
    private func fixture(
        on app: Application, withNotebook: Bool = true
    ) async throws
        -> APIAssignment
    {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(
            on: app, id: "setup_nb", courseID: courseID, withNotebook: withNotebook)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_nb", courseID: courseID, title: "Lab")
    }

    @Test func returnsNotebookWithCells() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Replace the default empty notebook with a two-cell one.
            try twoCellNotebook.write(
                toFile: app.testSetupsDirectory + "setup_nb.ipynb", atomically: true,
                encoding: .utf8)

            let output = try await GetNotebookTool().execute(
                GetNotebookTool.Input(assignmentPublicID: assignment.publicID), context(app))

            #expect(output.assignmentPublicID == assignment.publicID)
            #expect(output.cellCount == 2)
            // The returned notebook is a JSON object carrying a cells array.
            guard case .object(let root) = output.notebook, case .array(let cells)? = root["cells"]
            else {
                Issue.record("notebook output was not a JSON object with a cells array")
                return
            }
            #expect(cells.count == 2)
        }
    }

    @Test func returnsEmptyCellsForBlankNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await GetNotebookTool().execute(
                GetNotebookTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.cellCount == 0)
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetNotebookTool().execute(
                    GetNotebookTool.Input(assignmentPublicID: "zzzzzz"), context(app))
            }
        }
    }

    @Test func throwsWhenNoNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Setup without a flat notebook and only an empty zip → nothing to return.
            let assignment = try await fixture(on: app, withNotebook: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetNotebookTool().execute(
                    GetNotebookTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_nb", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_nb", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetNotebookTool().execute(
                    GetNotebookTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }
}

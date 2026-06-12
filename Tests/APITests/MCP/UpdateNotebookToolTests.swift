// Tests for UpdateNotebookTool (replace an assignment's starter notebook),
// backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateNotebookToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// Decodes a JSON string into a `JSONValue` for use as tool input.
    private func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private let twoCellNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Lab"]},
        {"cell_type":"code","metadata":{},"source":["x = 1\n"],"outputs":[],"execution_count":null}
        ]}
        """#

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

    @Test func writesNotebookAndPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdateNotebookTool().execute(
                UpdateNotebookTool.Input(
                    assignmentPublicID: assignment.publicID, notebook: try json(twoCellNotebook)),
                context(app))
            #expect(output.cellCount == 2)

            // Read the persisted notebook back through the canonical loader.
            let setup = try #require(try await APITestSetup.find("setup_nb", on: app.db))
            let data = try notebookData(for: setup)
            let reloaded = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let root) = reloaded, case .array(let cells)? = root["cells"] else {
                Issue.record("persisted notebook was not a JSON object with a cells array")
                return
            }
            #expect(cells.count == 2)
        }
    }

    @Test func createsFlatFileWhenAbsent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, withNotebook: false)
            // Setup begins with no flat notebook.
            let before = try #require(try await APITestSetup.find("setup_nb", on: app.db))
            #expect(before.notebookPath == nil)

            _ = try await UpdateNotebookTool().execute(
                UpdateNotebookTool.Input(
                    assignmentPublicID: assignment.publicID, notebook: try json(twoCellNotebook)),
                context(app))

            let after = try #require(try await APITestSetup.find("setup_nb", on: app.db))
            let path = try #require(after.notebookPath)
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func rejectsNonObjectNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateNotebookTool().execute(
                    UpdateNotebookTool.Input(
                        assignmentPublicID: assignment.publicID, notebook: .array([])),
                    context(app))
            }
        }
    }

    @Test func rejectsNotebookWithoutCells() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateNotebookTool().execute(
                    UpdateNotebookTool.Input(
                        assignmentPublicID: assignment.publicID,
                        notebook: try json(#"{"nbformat":4,"metadata":{}}"#)),
                    context(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateNotebookTool().execute(
                    UpdateNotebookTool.Input(
                        assignmentPublicID: "zzzzzz", notebook: try json(twoCellNotebook)),
                    context(app))
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
                _ = try await UpdateNotebookTool().execute(
                    UpdateNotebookTool.Input(
                        assignmentPublicID: assignment.publicID, notebook: try json(twoCellNotebook)),
                    context(app))
            }
        }
    }
}

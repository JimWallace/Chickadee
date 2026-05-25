// Tests for CreateAssignmentTool (create a new notebook-based assignment from
// scratch), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CreateAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private let twoCellNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Lab"]},
        {"cell_type":"code","metadata":{},"source":["x = 1\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// Course CS246 + enrolled instructor "tester".
    private func enrolledCourse(on app: Application) async throws {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
    }

    @Test func createsAssignmentWithNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            let output = try await CreateAssignmentTool().execute(
                CreateAssignmentTool.Input(
                    courseCode: "CS246", title: "  New Lab  ", notebook: try json(twoCellNotebook)),
                context(app))

            #expect(output.title == "New Lab")
            #expect(output.courseCode == "CS246")
            #expect(output.cellCount == 2)
            #expect(output.isOpen == false)
            #expect(!output.publicID.isEmpty)

            // Assignment + setup persisted; notebook readable; suite empty.
            let assignment = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            #expect(assignment.validationStatus == nil)
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(FileManager.default.fileExists(atPath: setup.zipPath))
            let props = try #require(setup.decodedManifest())
            #expect(props.testSuites.isEmpty)

            let data = try notebookData(for: setup)
            let reloaded = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let root) = reloaded, case .array(let cells)? = root["cells"] else {
                Issue.record("persisted notebook was not a JSON object with a cells array")
                return
            }
            #expect(cells.count == 2)
        }
    }

    @Test func emptyTitleThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "   ", notebook: try json(twoCellNotebook)),
                    context(app))
            }
        }
    }

    @Test func unknownCourseThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "NOPE99", title: "Lab", notebook: try json(twoCellNotebook)),
                    context(app))
            }
        }
    }

    @Test func rejectsNotebookWithoutCells() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "Lab",
                        notebook: try json(#"{"nbformat":4,"metadata":{}}"#)),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Course exists but the instructor isn't enrolled in it.
            _ = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "Lab", notebook: try json(twoCellNotebook)),
                    context(app))
            }
        }
    }
}

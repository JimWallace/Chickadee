// Tests for UpdateSolutionTool (replace an assignment's reference solution and
// re-validate), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateSolutionToolTests {
    private func context(_ app: Application, scopes: Set<ContentScope> = [.write]) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: scopes)
    }

    private func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private let twoCellSolution = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Solution"]},
        {"cell_type":"code","metadata":{},"source":["answer = 42\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// Number of cells in a notebook file, or 0 if absent/un-shaped.
    private func cellCount(ofFileAt path: String) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let nb = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let root) = nb, case .array(let cells)? = root["cells"] else { return 0 }
        return cells.count
    }

    /// Course + enrolled instructor "tester" + setup + assignment (no solution yet).
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_sol", courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_sol", courseID: courseID, title: "Lab")
    }

    @Test func storesSolutionAsPendingValidationSubmission() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdateSolutionTool().execute(
                UpdateSolutionTool.Input(
                    assignmentPublicID: assignment.publicID, notebook: try json(twoCellSolution)),
                context(app))

            #expect(output.cellCount == 2)
            #expect(output.validationStatus == "pending")

            // The assignment now links a fresh validation submission, pending.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            let subID = try #require(reloaded.validationSubmissionID)
            #expect(reloaded.validationStatus == "pending")

            // It is a validation (solution) submission attributed to the acting subject,
            // and holds the new solution content (cells survive kernel normalization).
            let sub = try #require(try await APISubmission.find(subID, on: app.db))
            #expect(sub.kind == APISubmission.Kind.validation)
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())
            #expect(sub.userID == tester.id)
            #expect(try cellCount(ofFileAt: sub.zipPath) == 2)
        }
    }

    @Test func roundTripsWithGetSolution() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await UpdateSolutionTool().execute(
                UpdateSolutionTool.Input(
                    assignmentPublicID: assignment.publicID, notebook: try json(twoCellSolution)),
                context(app))

            let got = try await GetSolutionTool().execute(
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID),
                context(app, scopes: [.read]))
            #expect(got.cellCount == 2)
        }
    }

    @Test func rejectsNonObjectNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSolutionTool().execute(
                    UpdateSolutionTool.Input(
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
                _ = try await UpdateSolutionTool().execute(
                    UpdateSolutionTool.Input(
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
                _ = try await UpdateSolutionTool().execute(
                    UpdateSolutionTool.Input(
                        assignmentPublicID: "zzzzzz", notebook: try json(twoCellSolution)),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            // "tester" exists but is NOT enrolled in the course.
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_sol", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sol", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSolutionTool().execute(
                    UpdateSolutionTool.Input(
                        assignmentPublicID: assignment.publicID, notebook: try json(twoCellSolution)),
                    context(app))
            }
        }
    }
}

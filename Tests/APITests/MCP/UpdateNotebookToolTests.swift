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

    /// Regression: an MCP content edit must re-enqueue validation even though
    /// the request carries no session `APIUser` (bearer auth only). Pre-fix,
    /// `scheduleValidationAfterSuiteEdit` fell back to `req.auth.require(...)`,
    /// threw 401 inside its swallow-all catch, and the edit silently kept the
    /// assignment's stale validationStatus with no validation enqueued.
    @Test func enqueuesValidationWithoutSessionUser() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())

            // An active compatible runner, so the availability pre-check passes
            // and the flow reaches the enqueue (where the 401 used to fire).
            let profile = RunnerProfile()
            profile.runnerID = "runner-mcp-validation"
            profile.displayName = "Runner MCP Validation"
            profile.platform = "linux"
            profile.architecture = "x86_64"
            profile.languageVersionsJSON = "[]"
            profile.capabilitiesJSON = "[]"
            profile.lastRegisteredAt = Date()
            profile.lastSeenAt = Date().addingTimeInterval(3600)
            profile.isActive = true
            try await profile.save(on: app.db)

            // A prior (complete) validation submission provides the solution
            // notebook `scheduleValidationAfterSuiteEdit` re-validates with.
            try await makeTestSubmission(
                on: app, id: "sub_nb_prior_validation", setupID: "setup_nb",
                userID: tester.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            assignment.validationSubmissionID = "sub_nb_prior_validation"
            try await assignment.save(on: app.db)

            let output = try await UpdateNotebookTool().execute(
                UpdateNotebookTool.Input(
                    assignmentPublicID: assignment.publicID, notebook: try json(twoCellNotebook)),
                context(app))

            #expect(output.validationStatus == "pending")

            let enqueued = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "setup_nb")
                .filter(\.$kind == APISubmission.Kind.validation)
                .filter(\.$status == "pending")
                .first()
            let pending = try #require(
                enqueued, "The notebook edit must enqueue a fresh validation submission")
            #expect(pending.userID == tester.id, "The validation is attributed to the acting subject")

            let after = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(after.validationStatus == "pending")
            #expect(after.validationSubmissionID == pending.id)
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

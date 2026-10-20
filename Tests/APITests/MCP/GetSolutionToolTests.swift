// Tests for GetSolutionTool (read an assignment's reference solution notebook),
// backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetSolutionToolTests {
    private let solutionNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Solution"]},
        {"cell_type":"code","metadata":{},"source":["answer = 42\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// Course + enrolled instructor "tester" + setup + assignment. When
    /// `withSolution` is true, attaches a `kind == .validation` submission
    /// carrying `solutionNotebook` and links it as the assignment's solution.
    private func fixture(on app: Application, withSolution: Bool = true) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(
            on: app, setupID: "setup_sol")
        let tester = try await mcpTestUser(on: app)

        if withSolution {
            let path = app.submissionsDirectory + "sub_sol.ipynb"
            try Data(solutionNotebook.utf8).write(to: URL(fileURLWithPath: path))
            let submission = APISubmission(
                id: "sub_sol",
                testSetupID: "setup_sol",
                zipPath: path,
                attemptNumber: 1,
                filename: "solution.ipynb",
                userID: try tester.requireID(),
                kind: APISubmission.Kind.validation)
            try await submission.save(on: app.db)
            assignment.validationSubmissionID = "sub_sol"
            try await assignment.save(on: app.db)
        }
        return assignment
    }

    @Test func returnsLinkedSolutionNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await GetSolutionTool().execute(
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))

            #expect(output.cellCount == 2)
            #expect(output.filename == "solution.ipynb")
            let isObject: Bool = {
                guard case .object = output.notebook else { return false }
                return true
            }()
            #expect(isObject, "solution must be returned as a JSON object")
        }
    }

    /// With no linked validation submission, the most recent `kind == .validation`
    /// submission for the setup is used as the solution.
    @Test func fallsBackToLatestValidationSubmission() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Unlink the explicit pointer; the fallback query should still find it.
            assignment.validationSubmissionID = nil
            try await assignment.save(on: app.db)

            let output = try await GetSolutionTool().execute(
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(output.cellCount == 2)
        }
    }

    @Test func throwsWhenNoSolutionOnFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, withSolution: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetSolutionTool().execute(
                    GetSolutionTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetSolutionTool().execute(
                    GetSolutionTool.Input(assignmentPublicID: "zzzzzz"), mcpContext(app))
            }
        }
    }
}

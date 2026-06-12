// Tests for GetSolutionTool (read an assignment's reference solution notebook),
// backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetSolutionToolTests {
    private func context(_ app: Application, scopes: Set<ContentScope> = [.read]) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: scopes)
    }

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
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_sol", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_sol", courseID: courseID, title: "Lab")

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
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID), context(app))

            #expect(output.cellCount == 2)
            #expect(output.filename == "solution.ipynb")
            let isObject: Bool = { if case .object = output.notebook { return true } else { return false } }()
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
                GetSolutionTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.cellCount == 2)
        }
    }

    @Test func throwsWhenNoSolutionOnFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, withSolution: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetSolutionTool().execute(
                    GetSolutionTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetSolutionTool().execute(
                    GetSolutionTool.Input(assignmentPublicID: "zzzzzz"), context(app))
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
                _ = try await GetSolutionTool().execute(
                    GetSolutionTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }
}

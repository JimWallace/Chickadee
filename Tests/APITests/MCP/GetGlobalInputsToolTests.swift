// Tests for GetGlobalInputsTool (read-only view of an assignment's global
// inputs), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetGlobalInputsToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    /// Manifest carrying one literal global variable and one expression.
    private let manifest =
        #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"globalVariables":[{"name":"limit","value":5}],"globalExpressions":[{"name":"offset","expression":"seed % 3"}]}"#

    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_gi", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_gi", courseID: courseID, title: "Lab")
    }

    @Test func returnsVariablesAndExpressions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await GetGlobalInputsTool().execute(
                GetGlobalInputsTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.assignmentPublicID == assignment.publicID)
            #expect(output.variables.map(\.name) == ["limit"])
            #expect(output.variables.first?.value == .int(5))
            #expect(output.expressions.map(\.name) == ["offset"])
            #expect(output.expressions.first?.expression == "seed % 3")
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await GetGlobalInputsTool().execute(
                    GetGlobalInputsTool.Input(assignmentPublicID: "ZZZ999"), context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            // Instructor exists but is NOT enrolled in the course.
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_gi", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_gi", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetGlobalInputsTool().execute(
                    GetGlobalInputsTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }
}

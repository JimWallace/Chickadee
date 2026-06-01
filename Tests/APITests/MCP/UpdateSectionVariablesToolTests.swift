// Tests for UpdateSectionVariablesTool (replace one section's personalization
// inputs), backed by a real test database.  The expression round-trip runs a
// real `python3` subprocess for the save-time eval check.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateSectionVariablesToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// One section ("sec1"), one global variable ("g") to exercise the
    /// cross-scope clash check.
    private let manifest = #"""
        {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,"globalVariables":[{"name":"g","value":1}],"sections":[{"id":"sec1","name":"Part A"}]}
        """#

    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_sv", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_sv", courseID: courseID, title: "Lab")
    }

    private func input(
        _ assignment: APIAssignment,
        sectionID: String = "sec1",
        variables: [FamilyVariable],
        expressions: [PersonalizationExpression]? = nil
    ) -> UpdateSectionVariablesTool.Input {
        UpdateSectionVariablesTool.Input(
            assignmentPublicID: assignment.publicID, sectionID: sectionID,
            variables: variables, expressions: expressions)
    }

    private func reload(
        _ assignment: APIAssignment, sectionID: String = "sec1", on db: Database
    ) async throws -> SectionInputsService.Inputs? {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        return try SectionInputsService.current(setup: setup, sectionID: sectionID)
    }

    @Test func roundTripsVariablesAndExpressions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdateSectionVariablesTool().execute(
                input(
                    assignment,
                    variables: [FamilyVariable(name: "cap", value: .int(7))],
                    expressions: [PersonalizationExpression(name: "pick", expression: "seed % 4")]),
                context(app))
            #expect(output.variables.map(\.name) == ["cap"])
            #expect(output.expressions.map(\.name) == ["pick"])

            let reloaded = try #require(try await reload(assignment, on: app.db))
            #expect(reloaded.variables.first?.value == .int(7))
            #expect(reloaded.expressions.first?.expression == "seed % 4")
        }
    }

    @Test func clearsWithEmptyLists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await UpdateSectionVariablesTool().execute(
                input(assignment, variables: [FamilyVariable(name: "cap", value: .int(7))]),
                context(app))
            _ = try await UpdateSectionVariablesTool().execute(
                input(assignment, variables: []), context(app))
            let reloaded = try #require(try await reload(assignment, on: app.db))
            #expect(reloaded.variables.isEmpty)
            #expect(reloaded.expressions.isEmpty)
        }
    }

    @Test func clashWithGlobalThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSectionVariablesTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "g", value: .int(2))]),
                    context(app))
            }
        }
    }

    @Test func reservedSeedNameThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSectionVariablesTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "seed", value: .int(1))]),
                    context(app))
            }
        }
    }

    @Test func unknownSectionThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSectionVariablesTool().execute(
                    input(
                        assignment, sectionID: "nope",
                        variables: [FamilyVariable(name: "cap", value: .int(1))]),
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
            try await makeTestSetup(on: app, id: "setup_sv", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sv", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateSectionVariablesTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "cap", value: .int(1))]),
                    context(app))
            }
        }
    }
}

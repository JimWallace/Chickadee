// Tests for UpdateGlobalInputsTool (replace an assignment's global inputs),
// backed by a real test database.  The happy path that includes an expression
// runs a real `python3` subprocess for the save-time eval check (mirrors the
// PersonalizationEvaluator tests).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdateGlobalInputsToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup (empty manifest, rebuildable zip) +
    /// assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_gi", courseID: courseID, manifest: emptyManifest)
        // applyPatternFamilies rebuilds the zip, so it must be a valid archive.
        try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_gi.zip")
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_gi", courseID: courseID, title: "Lab")
    }

    private func input(
        _ assignment: APIAssignment,
        variables: [FamilyVariable],
        expressions: [PersonalizationExpression]? = nil
    ) -> UpdateGlobalInputsTool.Input {
        UpdateGlobalInputsTool.Input(
            assignmentPublicID: assignment.publicID, variables: variables, expressions: expressions)
    }

    private func reloadInputs(
        _ assignment: APIAssignment, on db: Database
    ) async throws -> GlobalInputsService.Result {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        return try GlobalInputsService.current(setup: setup)
    }

    @Test func roundTripsVariablesAndExpressions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdateGlobalInputsTool().execute(
                input(
                    assignment,
                    variables: [FamilyVariable(name: "limit", value: .int(5))],
                    expressions: [PersonalizationExpression(name: "offset", expression: "seed % 3")]),
                context(app))
            #expect(output.variables.map(\.name) == ["limit"])
            #expect(output.expressions.map(\.name) == ["offset"])

            let reloaded = try await reloadInputs(assignment, on: app.db)
            #expect(reloaded.variables.first?.value == .int(5))
            #expect(reloaded.expressions.first?.expression == "seed % 3")
        }
    }

    @Test func clearsWithEmptyLists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await UpdateGlobalInputsTool().execute(
                input(assignment, variables: [FamilyVariable(name: "limit", value: .int(5))]),
                context(app))
            _ = try await UpdateGlobalInputsTool().execute(
                input(assignment, variables: []), context(app))
            let reloaded = try await reloadInputs(assignment, on: app.db)
            #expect(reloaded.variables.isEmpty)
            #expect(reloaded.expressions.isEmpty)
        }
    }

    @Test func invalidIdentifierThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateGlobalInputsTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "1bad", value: .int(1))]),
                    context(app))
            }
        }
    }

    @Test func reservedSeedNameThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateGlobalInputsTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "seed", value: .int(1))]),
                    context(app))
            }
        }
    }

    @Test func duplicateAcrossKindsThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateGlobalInputsTool().execute(
                    input(
                        assignment,
                        variables: [FamilyVariable(name: "n", value: .int(1))],
                        expressions: [PersonalizationExpression(name: "n", expression: "seed")]),
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
            try await makeTestSetup(on: app, id: "setup_gi", courseID: courseID, manifest: emptyManifest)
            try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_gi.zip")
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_gi", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateGlobalInputsTool().execute(
                    input(assignment, variables: [FamilyVariable(name: "n", value: .int(1))]),
                    context(app))
            }
        }
    }
}

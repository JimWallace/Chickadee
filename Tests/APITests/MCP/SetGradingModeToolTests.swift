// Tests for SetGradingModeTool (set an assignment's worker/browser grading
// path), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetGradingModeToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let browserManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#

    private func fixture(
        on app: Application, manifest: String, enroll: Bool = true
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        if enroll {
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        }
        try await makeTestSetup(on: app, id: "setup_gm", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_gm", courseID: courseID, title: "Lab")
    }

    @Test func setsGradingModeWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            #expect(assignment.visibility == .open)

            let out = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "worker"), context(app))
            #expect(out.gradingMode == "worker")

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode.rawValue == "worker")
            // A grading-mode change is not a content edit, so the assignment stays open.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func rejectsUnknownMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "nonsense"), context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "worker"), context(app))
            }
        }
    }
}

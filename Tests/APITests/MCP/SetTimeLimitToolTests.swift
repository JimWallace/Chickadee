// Tests for SetTimeLimitTool (set an assignment's default per-test execution
// time limit), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetTimeLimitToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let manifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#

    private func fixture(on app: Application, enroll: Bool = true) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        if enroll {
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        }
        try await makeTestSetup(on: app, id: "setup_tl", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_tl", courseID: courseID, title: "Lab")
    }

    @Test func setsDefaultTimeLimitWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let out = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 30), context(app))
            #expect(out.timeLimitSeconds == 30)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.timeLimitSeconds == 30)
            // Metadata-style edit: the assignment stays open, not closed.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func rejectsZero() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: 0), context(app))
            }
        }
    }

    @Test func rejectsNegative() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: -5), context(app))
            }
        }
    }

    @Test func rejectsAboveMax() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: 601), context(app))
            }
        }
    }

    @Test func acceptsBoundaryValues() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let low = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 1), context(app))
            #expect(low.timeLimitSeconds == 1)
            let high = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 600), context(app))
            #expect(high.timeLimitSeconds == 600)
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: assignment.publicID, seconds: 30), context(app))
            }
        }
    }
}

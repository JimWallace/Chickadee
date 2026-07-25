// Tests for SetMinimumRunnerVersionTool (set/clear an assignment's minimum
// native-runner version gate), backed by a real test database. Mirrors
// SetTimeLimitToolTests: metadata-only (no close), validation, enrollment +
// the `.instructor` role floor, and the get_suite / get_assignment read echo.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetMinimumRunnerVersionToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let manifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#

    /// A live course + setup + assignment, with `tester` (a *global student*)
    /// enrolled at the given per-course role.
    private func fixture(
        on app: Application, role: CourseRole = .instructor, enroll: Bool = true
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS241", name: "Systems")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "student")
        if enroll {
            try await APICourseEnrollment(userID: try tester.requireID(), courseID: courseID, role: role)
                .save(on: app.db)
        }
        try await makeTestSetup(on: app, id: "setup_mrv", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_mrv", courseID: courseID, title: "Lab")
    }

    @Test func setsGateWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let out = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                context(app))
            #expect(out.minimumRunnerVersion == "0.5.0")

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.minimumRunnerVersion == "0.5.0")
            // Metadata-style edit: the assignment stays open, not closed.
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .open)
        }
    }

    @Test func clearsGateOnNull() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                context(app))

            let cleared = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: nil),
                context(app))
            #expect(cleared.minimumRunnerVersion == nil)

            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.minimumRunnerVersion == nil)
            // The key is removed entirely, not written as null/empty.
            let dict = try #require(
                try JSONSerialization.jsonObject(with: Data(setup.manifest.utf8)) as? [String: Any])
            #expect(!dict.keys.contains("minimumRunnerVersion"))
        }
    }

    @Test func clearsGateOnBlankString() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                context(app))
            let cleared = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "  "),
                context(app))
            #expect(cleared.minimumRunnerVersion == nil)
        }
    }

    @Test func rejectsUnparseableVersion() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetMinimumRunnerVersionTool().execute(
                    .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "not-a-version"),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetMinimumRunnerVersionTool().execute(
                    .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                    context(app))
            }
        }
    }

    @Test func deniesTABelowInstructorFloor() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, role: .ta)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetMinimumRunnerVersionTool().execute(
                    .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                    context(app))
            }
        }
    }

    @Test func readToolsEchoTheGate() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await SetMinimumRunnerVersionTool().execute(
                .init(assignmentPublicID: assignment.publicID, minimumRunnerVersion: "0.5.0"),
                context(app))

            let suite = try await GetSuiteTool().execute(
                .init(assignmentPublicID: assignment.publicID), context(app))
            #expect(suite.minimumRunnerVersion == "0.5.0")

            let info = try await GetAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), context(app))
            #expect(info.minimumRunnerVersion == "0.5.0")
        }
    }
}

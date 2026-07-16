// Tests/APITests/MCP/MCPRoleFloorTests.swift
//
// #417: the MCP authoring surface enforces the per-course TA-vs-instructor line,
// mirroring the web. Content-editing tools require the `.ta` floor; course
// lifecycle / structure tools (create assignment, grading mode, sections)
// require `.instructor`. The acting subject here is a *global student* whose
// only staff standing is the per-course role under test, so these tests also
// prove MCP authority is purely per-course.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPRoleFloorTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """

    /// A live course + setup + assignment, with `tester` (a *global student*)
    /// enrolled at the given per-course role.
    private func fixture(
        on app: Application, role: CourseRole, code: String
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: code, name: "Role Floor")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "student")
        try await APICourseEnrollment(userID: try tester.requireID(), courseID: courseID, role: role)
            .save(on: app.db)
        try await makeTestSetup(on: app, id: "rf_setup_\(code)", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "rf_setup_\(code)", courseID: courseID, title: "Lab")
    }

    // MARK: - TA: content editing YES, course lifecycle NO

    @Test func taMayEditContentButNotLifecycle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, role: .ta, code: "TAFLOOR")

            // Content edit (set_time_limit → `.ta` floor) succeeds for a TA.
            let out = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 42), context(app))
            #expect(out.timeLimitSeconds == 42)

            // Lifecycle on the assignment resolver (set_grading_mode → `.instructor`)
            // is refused for a TA.
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), context(app))
            }

            // Lifecycle on the course resolver (create course section → `.instructor`)
            // is refused for a TA.
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateCourseSectionTool().execute(
                    .init(courseCode: "TAFLOOR", name: "Labs", defaultGradingMode: "browser"), context(app))
            }
        }
    }

    // MARK: - Instructor: both content editing AND lifecycle

    @Test func instructorMayEditContentAndLifecycle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, role: .instructor, code: "INSTFLOOR")

            // Content still works.
            let out = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: assignment.publicID, seconds: 55), context(app))
            #expect(out.timeLimitSeconds == 55)

            // Lifecycle now allowed — grading-mode flip and a new course section.
            let mode = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), context(app))
            #expect(mode.gradingMode == "browser")

            let section = try await CreateCourseSectionTool().execute(
                .init(courseCode: "INSTFLOOR", name: "Labs", defaultGradingMode: "browser"), context(app))
            #expect(section.name == "Labs")
        }
    }
}

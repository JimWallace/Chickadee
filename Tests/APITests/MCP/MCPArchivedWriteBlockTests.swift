// Tests/APITests/MCP/MCPArchivedWriteBlockTests.swift
//
// #417 Slice D-MCP: every MCP content-WRITE tool now routes through a
// write-only resolver (`authorizedAssignment[AndSetup]ForWrite`,
// `authorizeCourseWriteAccess`, `resolveCourseIDForWrite`,
// `resolveCourseSectionForEdit`) so it can't mutate an ARCHIVED course's
// content by id. The READ tools deliberately stay on the read resolvers
// (`authorizedAssignmentAndSetup`, `resolveCourseID`) so archived courses
// remain READABLE — the invariant the review flagged would break under a
// naive shared chokepoint. These tests pin both halves: writes blocked,
// reads still work, on the same archived fixtures.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPArchivedWriteBlockTests {
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

    /// Course + enrolled instructor + setup + assignment, optionally archived.
    private func fixture(
        on app: Application, archived: Bool, code: String = "ARCHMCP"
    ) async throws -> (course: APICourse, assignment: APIAssignment) {
        let course = try await makeTestCourse(on: app, code: code, name: "Archived MCP", archived: archived)
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "arch_setup_\(code)", courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "arch_setup_\(code)", courseID: courseID, title: "Lab")
        return (course, assignment)
    }

    // MARK: - Assignment-scoped content write (authorizedAssignmentAndSetupForWrite)

    @Test func contentWriteBlockedOnArchivedCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app, archived: true)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetTimeLimitTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, seconds: 42), context(app))
            }
        }
    }

    @Test func contentWriteSucceedsOnLiveCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Same tool + fixture shape, non-archived → must succeed, so the
            // block above is attributable to the archived state, not the fixture.
            let fx = try await fixture(on: app, archived: false, code: "LIVEMCP")
            let out = try await SetTimeLimitTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, seconds: 42), context(app))
            #expect(out.timeLimitSeconds == 42)
        }
    }

    // MARK: - Read invariant: archived courses stay READABLE (authorizedAssignmentAndSetup)

    @Test func readToolStillWorksOnArchivedCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app, archived: true, code: "ARCHRD")
            // get_suite routes through the READ resolver; it must NOT be blocked
            // by the archived state — grade audits / lookups stay available. The
            // call returning (rather than throwing MCPToolError) is the assertion.
            let out = try await GetSuiteTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID), context(app))
            #expect(out.items.isEmpty)
        }
    }

    // MARK: - Course-code write resolver (resolveCourseIDForWrite)

    @Test func createCourseSectionBlockedOnArchivedCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app, archived: true, code: "ARCHSEC")
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateCourseSectionTool().execute(
                    .init(courseCode: "ARCHSEC", name: "Labs", defaultGradingMode: "browser"), context(app))
            }
        }
    }

    // MARK: - Read invariant on the course-code resolver (resolveCourseID)

    @Test func listCourseSectionsStillWorksOnArchivedCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app, archived: true, code: "ARCHLS")
            // list_course_sections routes through the READ resolveCourseID; an
            // archived course must still list (here: empty), not 403.
            let out = try await ListCourseSectionsTool().execute(.init(courseCode: "ARCHLS"), context(app))
            #expect(out.sections.isEmpty)
        }
    }
}

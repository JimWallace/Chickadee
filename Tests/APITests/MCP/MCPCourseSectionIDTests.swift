// Tests/APITests/MCP/MCPCourseSectionIDTests.swift
//
// The one course-section id resolver behind set_assignment_course_section and
// the content-item tools (#2341).

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPCourseSectionIDTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester", grantedScopes: [.read])
    }

    @Test(arguments: [nil, "", "  ", "none", "NONE"])
    func anAbsentSectionIsNil(raw: String?) async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let id = try await resolveCourseSectionID(
                raw, inCourse: UUID(), owner: "assignment", context: context(app))
            #expect(id == nil)
        }
    }

    @Test func aSectionInThisCourseResolves() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let section = APICourseSection(
                name: "Labs", defaultGradingMode: "browser", sortOrder: 0, courseID: try course.requireID())
            try await section.save(on: app.db)
            let id = try await resolveCourseSectionID(
                " \(try section.requireID().uuidString) ", inCourse: try course.requireID(),
                owner: "assignment", context: context(app))
            #expect(id == section.id)
        }
    }

    @Test func aSectionInAnotherCourseIsRefusedNamingTheOwner() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let mine = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let other = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let section = APICourseSection(
                name: "Labs", defaultGradingMode: "browser", sortOrder: 0, courseID: try other.requireID())
            try await section.save(on: app.db)
            let raw = try section.requireID().uuidString
            await #expect(
                throws: MCPToolError.invalidArguments(
                    detail: "No course section with id \"\(raw)\" in this content item's course.")
            ) {
                _ = try await resolveCourseSectionID(
                    raw, inCourse: try mine.requireID(), owner: "content item", context: context(app))
            }
        }
    }

    @Test func aMalformedIdIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.invalidArguments(detail: "courseSectionID \"x\" is not a valid id.")) {
                _ = try await resolveCourseSectionID("x", inCourse: UUID(), owner: "assignment", context: context(app))
            }
        }
    }
}

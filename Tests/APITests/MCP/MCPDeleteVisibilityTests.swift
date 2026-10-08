// Tests/APITests/MCP/MCPDeleteVisibilityTests.swift
//
// The idempotent MCP deletes answer a row in a course the account is not
// enrolled in exactly as they answer an unknown id (#2342), and leave it in
// place. In a course the account can see, a role that is too low is still
// refused.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPDeleteVisibilityTests {
    private func context(_ app: Application, subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject, grantedScopes: [.read, .write])
    }

    /// "tester" is an instructor in CS246 only; CS136 is another course.
    private func fixture(on app: Application) async throws -> (visible: UUID, hidden: UUID) {
        let visible = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let hidden = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: visible.requireID())
        return (try visible.requireID(), try hidden.requireID())
    }

    @Test func aContentItemInAnUnseenCourseIsLeftAndReportedAsNotRemoved() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, hidden) = try await fixture(on: app)
            let item = APICourseContentItem(courseID: hidden, sortOrder: 0, title: "Theirs")
            try await item.save(on: app.db)
            let itemID = try item.requireID()

            let out = try await DeleteContentItemTool().execute(
                .init(contentItemID: itemID.uuidString), context(app, subject: "tester"))
            #expect(!out.removed)
            #expect(try await APICourseContentItem.find(itemID, on: app.db) != nil)
        }
    }

    @Test func aCourseSectionInAnUnseenCourseIsLeftAndReportedAsNotRemoved() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, hidden) = try await fixture(on: app)
            let section = APICourseSection(
                name: "Theirs", defaultGradingMode: "browser", sortOrder: 0, courseID: hidden)
            try await section.save(on: app.db)
            let sectionID = try section.requireID()

            let out = try await DeleteCourseSectionTool().execute(
                .init(courseSectionID: sectionID.uuidString), context(app, subject: "tester"))
            #expect(!out.removed)
            #expect(try await APICourseSection.find(sectionID, on: app.db) != nil)
        }
    }

    @Test func aVisibleCourseStillRefusesARoleThatIsTooLow() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (visible, _) = try await fixture(on: app)
            let student = try await makeTestUser(on: app, username: "stu", role: "mcp")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: visible)
            let section = APICourseSection(
                name: "Labs", defaultGradingMode: "browser", sortOrder: 0, courseID: visible)
            try await section.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteCourseSectionTool().execute(
                    .init(courseSectionID: try section.requireID().uuidString), context(app, subject: "stu"))
            }
        }
    }
}

// Tests for the course content-item MCP tools — list_content_items,
// create_content_item, update_content_item, delete_content_item, and
// reorder_content_items. Backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseContentItemToolsTests {
    private func context(_ app: Application, subject: String = "tester") -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: [.read, .write]
        )
    }

    /// Course + enrolled instructor "tester".
    @discardableResult
    private func fixture(on app: Application) async throws -> APICourse {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: course.requireID())
        return course
    }

    @discardableResult
    private func makeSection(
        on app: Application, name: String, order: Int, courseID: UUID
    ) async throws
        -> APICourseSection
    {
        let section = APICourseSection(
            name: name, defaultGradingMode: "browser", sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    // MARK: - create + list

    @Test func createsAndListsAContentItem() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let section = try await makeSection(
                on: app, name: "Lectures", order: 1, courseID: course.requireID())
            let sectionIDStr = try section.requireID().uuidString

            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Lecture 1", kind: "notebook",
                    links: [
                        .init(label: "PDF", url: "https://example.com/l1.pdf"),
                        .init(label: "Notebook", url: "/materials/l1.ipynb"),
                    ],
                    description: "Intro", updatedLabel: "2026-05-11",
                    courseSectionID: sectionIDStr, isPublished: true),
                context(app))
            #expect(created.title == "Lecture 1")
            #expect(created.kind == "notebook")
            #expect(created.links.count == 2)
            #expect(created.courseSectionID == sectionIDStr)

            let listed = try await ListContentItemsTool().execute(.init(courseCode: "CS246"), context(app))
            #expect(listed.contentItems.count == 1)
            #expect(listed.contentItems.first?.title == "Lecture 1")
            #expect(listed.contentItems.first?.links.map(\.label) == ["PDF", "Notebook"])
        }
    }

    @Test func createRejectsEmptyTitle() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "CS246", title: "   ", kind: nil, links: nil, description: nil,
                        updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                    context(app))
            }
        }
    }

    @Test func createRejectsUnsafeLinkURL() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "CS246", title: "Bad", kind: nil,
                        links: [.init(label: "x", url: "javascript:alert(1)")],
                        description: nil, updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                    context(app))
            }
        }
    }

    // MARK: - update

    @Test func updatesFieldsAndMovesSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeSection(on: app, name: "A", order: 1, courseID: courseID)
            let b = try await makeSection(on: app, name: "B", order: 2, courseID: courseID)
            let aIDStr = try a.requireID().uuidString
            let bIDStr = try b.requireID().uuidString

            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Item", kind: "link", links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: aIDStr, isPublished: true),
                context(app))

            let updated = try await UpdateContentItemTool().execute(
                .init(
                    contentItemID: created.contentItemID, title: "Renamed", kind: "slides",
                    links: [.init(label: "Deck", url: "https://example.com/d.pdf")],
                    description: "", updatedLabel: "2026-06-01", isPublished: false,
                    courseSectionID: bIDStr),
                context(app))
            #expect(updated.title == "Renamed")
            #expect(updated.kind == "slides")
            #expect(updated.links.count == 1)
            #expect(updated.description == nil)  // "" clears
            #expect(updated.isPublished == false)
            #expect(updated.courseSectionID == bIDStr)
        }
    }

    @Test func updateRequiresAtLeastOneField() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Item", kind: nil, links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                context(app))
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateContentItemTool().execute(
                    .init(
                        contentItemID: created.contentItemID, title: nil, kind: nil, links: nil,
                        description: nil, updatedLabel: nil, isPublished: nil, courseSectionID: nil),
                    context(app))
            }
        }
    }

    // MARK: - delete

    @Test func deletesAContentItem() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Doomed", kind: nil, links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                context(app))
            let out = try await DeleteContentItemTool().execute(
                .init(contentItemID: created.contentItemID), context(app))
            #expect(out.removed)
            let id = try #require(UUID(uuidString: created.contentItemID))
            #expect(try await APICourseContentItem.find(id, on: app.db) == nil)
        }
    }

    @Test func deleteUnknownIsIdempotent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let out = try await DeleteContentItemTool().execute(
                .init(contentItemID: UUID().uuidString), context(app))
            #expect(!out.removed)
        }
    }

    // MARK: - reorder

    @Test func reordersContentItems() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let section = try await makeSection(
                on: app, name: "Lectures", order: 1, courseID: course.requireID())
            let sid = try section.requireID().uuidString
            let one = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "One", kind: nil, links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: sid, isPublished: nil), context(app))
            let two = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "Two", kind: nil, links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: sid, isPublished: nil), context(app))

            let out = try await ReorderContentItemsTool().execute(
                .init(
                    courseCode: "CS246",
                    orderedContentItemIDs: [two.contentItemID, one.contentItemID]),
                context(app))
            #expect(out.contentItems.map(\.title) == ["Two", "One"])

            let listed = try await ListContentItemsTool().execute(.init(courseCode: "CS246"), context(app))
            #expect(listed.contentItems.map(\.title) == ["Two", "One"])
        }
    }

    // MARK: - authorization

    @Test func createDeniedForStudent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let student = try await makeTestUser(on: app, username: "pupil", role: "student")
            try await makeTestEnrollment(
                on: app, userID: student.requireID(), courseID: course.requireID())
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "CS246", title: "Nope", kind: nil, links: nil, description: nil,
                        updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                    context(app, subject: "pupil"))
            }
        }
    }

    @Test func createAllowedForTA() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let ta = try await makeTestUser(on: app, username: "ta_user", role: "student")
            // Manually enroll at the TA rung (content authoring is TA+).
            let enrollment = APICourseEnrollment(
                userID: try ta.requireID(), courseID: try course.requireID(), role: .ta)
            try await enrollment.save(on: app.db)

            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "TA material", kind: nil, links: nil,
                    description: nil, updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                context(app, subject: "ta_user"))
            #expect(created.title == "TA material")
        }
    }

    @Test func deniesForeignCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)  // tester enrolled only in CS246
            _ = try await makeTestCourse(on: app, code: "CS999", name: "Other")
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateContentItemTool().execute(
                    .init(
                        courseCode: "CS999", title: "Sneaky", kind: nil, links: nil, description: nil,
                        updatedLabel: nil, courseSectionID: nil, isPublished: nil),
                    context(app))
            }
        }
    }

    // MARK: - model behaviour

    @Test func deletingSectionUngroupsContentItems() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let section = try await makeSection(
                on: app, name: "Lectures", order: 1, courseID: course.requireID())
            let created = try await CreateContentItemTool().execute(
                .init(
                    courseCode: "CS246", title: "L1", kind: nil, links: nil, description: nil,
                    updatedLabel: nil, courseSectionID: section.requireID().uuidString,
                    isPublished: nil), context(app))

            try await section.delete(on: app.db)

            let id = try #require(UUID(uuidString: created.contentItemID))
            let reloaded = try #require(try await APICourseContentItem.find(id, on: app.db))
            #expect(reloaded.sectionID == nil, "content item should be ungrouped, not deleted")
        }
    }
}

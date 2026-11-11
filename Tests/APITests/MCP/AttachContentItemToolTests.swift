// Tests for attach_content_item: it attaches a content item to an assignment
// in its course (taking the assignment's section), detaches it again, refuses
// a heading and an assignment in another course, and reports whether a
// student without an extension sees the item before and after.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct AttachContentItemToolTests {
    private func makeSection(on app: Application, name: String, courseID: UUID) async throws -> APICourseSection {
        let section = APICourseSection(
            name: name, defaultAssignmentType: .lab, sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    private func makeItem(
        on app: Application, title: String, courseID: UUID, sectionID: UUID?,
        kind: ContentItemKind = .slides
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: 1, title: title, kind: kind,
            links: [ContentLink(label: "Slides", url: "https://example.com/slides.pdf")])
        try await item.save(on: app.db)
        return item
    }

    @Test func attachesTakesTheSectionAndListsIt() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-1")
            let courseID = assignment.courseID
            let week = try await makeSection(on: app, name: "Week 1", courseID: courseID)
            assignment.sectionID = try week.requireID()
            assignment.visibility = .open
            try await assignment.save(on: app.db)
            let item = try await makeItem(on: app, title: "Lab 1 slides", courseID: courseID, sectionID: nil)

            let out = try await AttachContentItemTool().execute(
                .init(contentItemID: try item.requireID().uuidString, assignmentPublicID: assignment.publicID),
                mcpContext(app))
            #expect(out.contentItem.attachedAssignmentPublicID == assignment.publicID)
            #expect(out.contentItem.courseSectionID == (try week.requireID().uuidString))
            #expect(out.wasVisibleToStudents)
            #expect(out.isVisibleToStudents)

            let listed = try await ListContentItemsTool().execute(.init(courseCode: "CS246"), mcpContext(app))
            #expect(listed.contentItems.first?.attachedAssignmentPublicID == assignment.publicID)
        }
    }

    @Test func reportsAnItemThatTheAttachHides() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-2")
            assignment.visibility = .closed
            assignment.dueAt = Date().addingTimeInterval(7 * 24 * 3600)
            try await assignment.save(on: app.db)
            let item = try await makeItem(on: app, title: "Reading", courseID: assignment.courseID, sectionID: nil)

            let out = try await AttachContentItemTool().execute(
                .init(contentItemID: try item.requireID().uuidString, assignmentPublicID: assignment.publicID),
                mcpContext(app))
            #expect(out.wasVisibleToStudents)
            #expect(!out.isVisibleToStudents)
        }
    }

    @Test(arguments: ["", "  "])
    func detachesIntoTheEndOfTheAssignmentsCurrentSection(_ detachToken: String) async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-3")
            let courseID = assignment.courseID
            let week1 = try await makeSection(on: app, name: "Week 1", courseID: courseID)
            let week2 = try await makeSection(on: app, name: "Week 2", courseID: courseID)
            // Attached while the assignment sat in Week 1; the assignment has
            // since moved to Week 2, where another item already sits.
            let item = try await makeItem(on: app, title: "Slides", courseID: courseID, sectionID: week1.requireID())
            item.assignmentID = try assignment.requireID()
            try await item.save(on: app.db)
            assignment.sectionID = try week2.requireID()
            assignment.sortOrder = 1
            try await assignment.save(on: app.db)
            let neighbour = try await makeItem(
                on: app, title: "Reading", courseID: courseID, sectionID: week2.requireID())
            neighbour.sortOrder = 2
            try await neighbour.save(on: app.db)

            let out = try await AttachContentItemTool().execute(
                .init(contentItemID: try item.requireID().uuidString, assignmentPublicID: detachToken),
                mcpContext(app))
            #expect(out.contentItem.attachedAssignmentPublicID == nil)
            let stored = try #require(try await APICourseContentItem.find(item.requireID(), on: app.db))
            #expect(stored.assignmentID == nil)
            #expect(stored.sectionID == (try week2.requireID()))
            #expect(stored.sortOrder == 3)
        }
    }

    @Test func reattachingToTheSameAssignmentChangesNothing() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-6")
            let item = try await makeItem(on: app, title: "Slides", courseID: assignment.courseID, sectionID: nil)
            item.assignmentID = try assignment.requireID()
            item.sortOrder = 7
            try await item.save(on: app.db)

            let out = try await AttachContentItemTool().execute(
                .init(contentItemID: try item.requireID().uuidString, assignmentPublicID: assignment.publicID),
                mcpContext(app))
            #expect(out.contentItem.attachedAssignmentPublicID == assignment.publicID)
            let stored = try #require(try await APICourseContentItem.find(item.requireID(), on: app.db))
            #expect(stored.sortOrder == 7)
        }
    }

    @Test func refusesAHeading() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-4")
            let heading = try await makeItem(
                on: app, title: "Part A", courseID: assignment.courseID, sectionID: nil, kind: .heading)

            await #expect(throws: MCPToolError.self) {
                _ = try await AttachContentItemTool().execute(
                    .init(
                        contentItemID: try heading.requireID().uuidString,
                        assignmentPublicID: assignment.publicID),
                    mcpContext(app))
            }
            let stored = try #require(try await APICourseContentItem.find(heading.requireID(), on: app.db))
            #expect(stored.assignmentID == nil)
        }
    }

    @Test func refusesAnAssignmentInAnotherCourse() async throws {
        try await withTestApp { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "attach-5")
            let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
            let item = try await makeItem(on: app, title: "Notes", courseID: other.requireID(), sectionID: nil)
            let user = try await mcpTestUser(on: app)
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: other.requireID())

            await #expect(throws: MCPToolError.self) {
                _ = try await AttachContentItemTool().execute(
                    .init(
                        contentItemID: try item.requireID().uuidString,
                        assignmentPublicID: assignment.publicID),
                    mcpContext(app))
            }
        }
    }
}

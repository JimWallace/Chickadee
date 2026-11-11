// Tests/APITests/Assignments/AssignmentMoveAttachedItemTests.swift
//
// Moving an assignment to another course section (`CourseSectionService
// .moveAssignment`, behind the dashboard's drag and MCP
// `set_assignment_course_section`) also moves the content items attached to
// it, so an attached item keeps its assignment's section, as
// `CourseContentService.attach` sets it. Their `sortOrder` is left alone:
// attached items are not section items.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(10))) final class AssignmentMoveAttachedItemTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-move-attached")
    }

    // MARK: - Helpers

    private func makeSection(name: String, order: Int, courseID: UUID) async throws -> APICourseSection {
        let section = APICourseSection(
            name: name, sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    private func makeLab(
        setupID: String, title: String, courseID: UUID, sectionID: UUID?, order: Int
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: title)
        assignment.sectionID = sectionID
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
        return assignment
    }

    private func makeSlides(
        title: String, courseID: UUID, sectionID: UUID?, order: Int
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: order, title: title, kind: .slides,
            links: [ContentLink(label: "Slides", url: "https://example.com/\(order).pdf")])
        try await item.save(on: app.db)
        return item
    }

    private func reload(_ item: APICourseContentItem) async throws -> APICourseContentItem {
        try #require(try await APICourseContentItem.find(try item.requireID(), on: app.db))
    }

    // MARK: - Tests

    @Test func moveCarriesAttachedItemsAndKeepsTheirOrder() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "MV_ATT", mode: .auto)
            let courseID = try course.requireID()
            let week1 = try await makeSection(name: "Week 1", order: 1, courseID: courseID)
            let week2 = try await makeSection(name: "Week 2", order: 2, courseID: courseID)
            let lab = try await makeLab(
                setupID: "mv_att_lab", title: "Lab", courseID: courseID, sectionID: week1.id, order: 1)
            let slides = try await makeSlides(title: "Slides", courseID: courseID, sectionID: week1.id, order: 7)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)
            // A standalone item in the same section stays where it is.
            let lecture = try await makeSlides(title: "Lecture", courseID: courseID, sectionID: week1.id, order: 2)

            try await CourseSectionService.moveAssignment(lab, toSection: week2.id, on: app.db)

            var reloaded = try await reload(slides)
            #expect(reloaded.assignmentID == lab.id)
            #expect(reloaded.sectionID == week2.id)
            #expect(reloaded.sortOrder == 7)
            #expect(try await reload(lecture).sectionID == week1.id)

            // Ungrouping the assignment ungroups its material too.
            try await CourseSectionService.moveAssignment(lab, toSection: nil, on: app.db)
            reloaded = try await reload(slides)
            #expect(reloaded.sectionID == nil)
            #expect(reloaded.sortOrder == 7)
        }
    }

    @Test func dashboardMoveCarriesAttachedItems() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "MV_ATT_WEB", mode: .auto)
            let courseID = try course.requireID()
            let target = try await makeSection(name: "Target", order: 1, courseID: courseID)
            let targetID = try target.requireID()
            let lab = try await makeLab(
                setupID: "mv_att_web_lab", title: "Lab", courseID: courseID, sectionID: nil, order: 1)
            let slides = try await makeSlides(title: "Slides", courseID: courseID, sectionID: nil, order: 2)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)

            let cookie = try await loginUser(
                username: "mv_att_web_instr", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("mv_att_web_instr", on: app)
            let (token, boundCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            struct MoveBody: Content { var sectionID: String }
            try await app.asyncTest(
                .POST, "/instructor/\(lab.publicID)/section",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    req.headers.add(name: "x-csrf-token", value: token)
                    req.headers.contentType = .json
                    try req.content.encode(MoveBody(sectionID: targetID.uuidString))
                },
                afterResponse: { res in #expect(res.status == .ok) })

            #expect(try await reload(slides).sectionID == targetID)
        }
    }
}

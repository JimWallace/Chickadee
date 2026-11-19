// Tests/APITests/Assignments/ContentItemAttachToAssignmentTests.swift
//
// A content item attached to an assignment (`course_content_items.assignment_id`):
// the material edit form's "Show on" select attaches and detaches it, the
// service refuses a heading and another course's assignment, an assignment
// delete detaches it, a section reorder leaves it out, the course clone and
// the bundle carry it, and the instructor dashboard draws it inside the
// assignment's row.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(10))) final class ContentItemAttachToAssignmentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-attach-material")
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
        title: String, courseID: UUID, sectionID: UUID?, order: Int, kind: ContentItemKind = .slides
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: order, title: title, kind: kind,
            links: [ContentLink(label: "Slides", url: "https://example.com/\(order).pdf")])
        try await item.save(on: app.db)
        return item
    }

    private func staffCookie(_ username: String) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        try await promoteToInstructor(username, on: app)
        return cookie
    }

    /// The material edit form, as the page posts it.
    private struct EditBody: Content {
        var title: String
        var kind: String
        var linkLabels: [String]
        var linkURLs: [String]
        var description: String
        var updatedLabel: String
        var isPublished: String
        var assignmentID: String
        var csrf: String
        enum CodingKeys: String, CodingKey {
            case title, kind, linkLabels, linkURLs, description, updatedLabel, isPublished, assignmentID
            case csrf = "_csrf"
        }
    }

    /// Posts the material edit form with `assignmentID` as the "Show on" value.
    private func postEdit(
        _ item: APICourseContentItem, kind: String = "slides", showOn: String, cookie: String,
        expect status: HTTPStatus = .seeOther
    ) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        let body = EditBody(
            title: item.title, kind: kind, linkLabels: ["Slides"], linkURLs: ["https://example.com/slides.pdf"],
            description: "", updatedLabel: "", isPublished: "true", assignmentID: showOn, csrf: token)
        try await app.asyncTest(
            .POST, "/instructor/content-items/\(try item.requireID())/edit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in #expect(res.status == status) })
    }

    private func reload(_ item: APICourseContentItem) async throws -> APICourseContentItem {
        try #require(try await APICourseContentItem.find(try item.requireID(), on: app.db))
    }

    // MARK: - Attach and detach through the edit form

    @Test func showOnAttachesThenDetaches() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_FORM", mode: .auto)
            let courseID = try course.requireID()
            let week1 = try await makeSection(name: "Week 1", order: 1, courseID: courseID)
            let lab = try await makeLab(
                setupID: "am_form_lab", title: "Lab 0", courseID: courseID, sectionID: week1.id, order: 1)
            // Ungrouped to begin with: attaching moves it into the lab's week.
            let slides = try await makeSlides(title: "Lab 0 slides", courseID: courseID, sectionID: nil, order: 2)
            let cookie = try await staffCookie("am_form_instr")

            try await postEdit(slides, showOn: lab.publicID, cookie: cookie)
            var reloaded = try await reload(slides)
            #expect(reloaded.assignmentID == lab.id)
            #expect(reloaded.sectionID == week1.id)

            try await postEdit(slides, showOn: "", cookie: cookie)
            reloaded = try await reload(slides)
            #expect(reloaded.assignmentID == nil)
            #expect(reloaded.sectionID == week1.id)
        }
    }

    @Test func showOnAnotherCoursesAssignmentIsRefused() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_CROSS", mode: .auto)
            let other = try await makeTestCourse(on: app, code: "AM_OTHER", mode: .auto)
            let foreignLab = try await makeLab(
                setupID: "am_cross_lab", title: "Foreign", courseID: try other.requireID(), sectionID: nil,
                order: 1)
            let slides = try await makeSlides(
                title: "Slides", courseID: try course.requireID(), sectionID: nil, order: 1)
            let cookie = try await staffCookie("am_cross_instr")

            try await postEdit(slides, showOn: foreignLab.publicID, cookie: cookie, expect: .badRequest)
            #expect(try await reload(slides).assignmentID == nil)
        }
    }

    @Test func headingCannotAttachAndTheEditIsNotSaved() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_HEAD", mode: .auto)
            let courseID = try course.requireID()
            let lab = try await makeLab(
                setupID: "am_head_lab", title: "Lab", courseID: courseID, sectionID: nil, order: 1)
            let item = try await makeSlides(title: "Slides", courseID: courseID, sectionID: nil, order: 2)
            let cookie = try await staffCookie("am_head_instr")

            // Kind changed to heading in the same edit: the attach is refused
            // and the transaction keeps the kind as it was.
            try await postEdit(item, kind: "heading", showOn: lab.publicID, cookie: cookie, expect: .badRequest)
            let reloaded = try await reload(item)
            #expect(reloaded.assignmentID == nil)
            #expect(reloaded.kind == .slides)
        }
    }

    // MARK: - Lifecycle

    @Test func deletingTheAssignmentDetachesItsMaterial() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_DEL", mode: .auto)
            let courseID = try course.requireID()
            let lab = try await makeLab(
                setupID: "am_del_lab", title: "Lab", courseID: courseID, sectionID: nil, order: 1)
            let slides = try await makeSlides(title: "Slides", courseID: courseID, sectionID: nil, order: 2)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)

            try await app.db.transaction { tx in _ = try await AssignmentDeletion.deleteRows(of: lab, on: tx) }

            let reloaded = try await reload(slides)
            #expect(reloaded.assignmentID == nil)
        }
    }

    // MARK: - Ordering

    @Test func sectionReorderLeavesAttachedMaterialOut() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_ORDER", mode: .auto)
            let courseID = try course.requireID()
            let week = try await makeSection(name: "Week", order: 1, courseID: courseID)
            let sectionID = try week.requireID()
            let lecture = try await makeSlides(title: "Lecture", courseID: courseID, sectionID: sectionID, order: 1)
            let lab = try await makeLab(
                setupID: "am_order_lab", title: "Lab", courseID: courseID, sectionID: sectionID, order: 2)
            let slides = try await makeSlides(title: "Lab slides", courseID: courseID, sectionID: sectionID, order: 3)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)

            // The section's items are the lab and the lecture; the list is complete
            // without the attached slides.
            let labItem = SortOrderItem.assignment(publicID: lab.publicID)
            let lectureItem = SortOrderItem.content(try lecture.requireID())
            let slidesItem = SortOrderItem.content(try slides.requireID())
            let renumbered = try await SortOrderRenumbering.renumberSectionItems(
                [labItem, lectureItem], inCourse: courseID, on: app.db)
            #expect(renumbered.count == 2)

            // Naming the attached slides is an unknown item.
            let db = app.db
            await #expect(throws: ReorderError.self) {
                _ = try await SortOrderRenumbering.renumberSectionItems(
                    [labItem, lectureItem, slidesItem], inCourse: courseID, on: db)
            }
        }
    }

    // MARK: - Clone and bundle

    @Test func cloneAttachesTheCopyToTheCopiedAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("am_clone_admin", on: app)
            let course = APICourse(
                code: "AM_CL", name: "Attach Clone", enrollmentMode: .closed,
                term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            let lab = try await makeLab(
                setupID: "am_clone_lab", title: "Lab 0", courseID: courseID, sectionID: nil, order: 1)
            let slides = try await makeSlides(title: "Lab 0 slides", courseID: courseID, sectionID: nil, order: 2)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)

            let path = "/admin/courses/\(courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            let form = [
                "code": "AM_CL", "name": "Attach Clone 2", "termYear": "2027", "termSeason": "winter",
                "_csrf": token,
            ]
            try await app.asyncTest(
                .POST, path + "/clone",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(form, as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            let clone = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "AM_CL").filter(\.$id != courseID).first())
            let cloneID = try clone.requireID()
            let clonedLab = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == cloneID).first())
            let clonedSlides = try #require(
                try await APICourseContentItem.query(on: app.db).filter(\.$courseID == cloneID).first())
            #expect(clonedSlides.assignmentID == clonedLab.id)
            #expect(clonedSlides.assignmentID != lab.id)
        }
    }

    @Test func bundleItemCarriesItsAssignmentAndOldBundlesDecode() async throws {
        try await withApp(app) { _ in
            let item = BundledContentItem(
                sectionBundleID: nil, title: "Lab 0 slides", kind: "slides", description: nil, links: [],
                updatedLabel: nil, isPublished: true, sortOrder: 1, assignmentBundleID: "assign_1")
            let decoded = try JSONDecoder().decode(BundledContentItem.self, from: try JSONEncoder().encode(item))
            #expect(decoded.assignmentBundleID == "assign_1")

            // A bundle exported before the field existed has no key.
            let old = Data(
                #"{"title":"Old","kind":"link","links":[],"isPublished":true,"sortOrder":1}"#.utf8)
            #expect(try JSONDecoder().decode(BundledContentItem.self, from: old).assignmentBundleID == nil)
        }
    }

    // MARK: - Instructor dashboard

    @Test func instructorDashboardDrawsTheMaterialInsideTheLabRow() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "AM_DASH", mode: .auto)
            let courseID = try course.requireID()
            let week = try await makeSection(name: "Week 1", order: 1, courseID: courseID)
            let lab = try await makeLab(
                setupID: "am_dash_lab", title: "DashLab", courseID: courseID, sectionID: week.id, order: 1)
            let slides = try await makeSlides(title: "DashSlides", courseID: courseID, sectionID: week.id, order: 2)
            try await CourseContentService.attach(slides, toAssignment: try lab.requireID(), on: app.db)
            let slidesID = try slides.requireID().uuidString
            let cookie = try await staffCookie("am_dash_instr")

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Not a draggable row of its own...
                    #expect(!html.contains("data-content-item-id=\"\(slidesID)\""))
                    // ...but a line inside the lab's row, with its edit form,
                    // where "Show on" names the lab as selected.
                    #expect(html.contains("data-attached-content-item-id=\"\(slidesID)\""))
                    #expect(html.contains("DashSlides"))
                    #expect(html.contains(#"value="\#(lab.publicID)" selected"#))
                })
        }
    }
}

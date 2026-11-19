// Tests/APITests/Assignments/ContentItemVisibilityTests.swift
//
// When a student sees a content item attached to an assignment
// (`ContentItemVisibility`): once the assignment has opened, and after a
// deadline close, and whenever this student can complete it (an extension);
// never while it is a draft, a staff-only preview or not yet started. The student course page draws the item's buttons on the
// assignment's row and no row of its own, and the hosted file route applies
// the same rule.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentItemVisibilityTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-material-visibility")
    }

    // MARK: - The rule

    /// One assignment state and whether a student sees the attached material.
    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let visibility: AssignmentVisibility
        /// Seconds from now; nil for no due date.
        let dueOffset: TimeInterval?
        /// Seconds from now; nil for no open date.
        let startsOffset: TimeInterval?
        let itemPublished: Bool
        let visible: Bool
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "open", visibility: .open, dueOffset: 3600, startsOffset: nil, itemPublished: true, visible: true),
        Case(
            name: "closed after its deadline", visibility: .closed, dueOffset: -3600, startsOffset: nil,
            itemPublished: true, visible: true),
        Case(
            name: "closed before its deadline", visibility: .closed, dueOffset: 3600, startsOffset: nil,
            itemPublished: true, visible: false),
        Case(
            name: "closed with no deadline", visibility: .closed, dueOffset: nil, startsOffset: nil,
            itemPublished: true, visible: false),
        Case(
            name: "staff-only preview", visibility: .preview, dueOffset: -3600, startsOffset: nil,
            itemPublished: true, visible: false),
        Case(
            name: "open with a future open date", visibility: .open, dueOffset: 7200, startsOffset: 3600,
            itemPublished: true, visible: false),
        Case(
            name: "open but the item is hidden", visibility: .open, dueOffset: 3600, startsOffset: nil,
            itemPublished: false, visible: false),
    ]

    @Test(arguments: cases) func attachedMaterialFollowsItsAssignment(_ testCase: Case) async throws {
        try await withApp(app) { _ in
            let now = Date()
            let courseID = UUID()
            let assignment = APIAssignment(
                testSetupID: "vis_setup", title: "Lab", slug: "lab",
                dueAt: testCase.dueOffset.map { now.addingTimeInterval($0) },
                startsAt: testCase.startsOffset.map { now.addingTimeInterval($0) },
                visibility: testCase.visibility, sortOrder: 1, validationStatus: "passed", sectionID: nil,
                courseID: courseID)
            assignment.id = UUID()
            let item = APICourseContentItem(
                courseID: courseID, sortOrder: 1, title: "Slides", kind: .slides, isPublished: testCase.itemPublished,
                assignmentID: assignment.id)
            #expect(
                ContentItemVisibility.isVisibleToStudents(item, attachedTo: assignment, now: now) == testCase.visible)
        }
    }

    @Test func standaloneItemFollowsOnlyItsOwnFlag() async throws {
        try await withApp(app) { _ in
            let published = APICourseContentItem(courseID: UUID(), sortOrder: 1, title: "Notes", isPublished: true)
            let hidden = APICourseContentItem(courseID: UUID(), sortOrder: 1, title: "Notes", isPublished: false)
            #expect(ContentItemVisibility.isVisibleToStudents(published, attachedTo: nil))
            #expect(!ContentItemVisibility.isVisibleToStudents(hidden, attachedTo: nil))
        }
    }

    @Test func studentWhoCanSubmitSeesTheMaterialOfAClosedLab() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let assignment = APIAssignment(
                id: UUID(), testSetupID: "vis_ext", title: "Lab", dueAt: now.addingTimeInterval(3600),
                visibility: .closed, courseID: UUID())
            let item = APICourseContentItem(
                courseID: assignment.courseID, sortOrder: 1, title: "Slides", isPublished: true,
                assignmentID: assignment.id)
            #expect(!ContentItemVisibility.isVisibleToStudents(item, attachedTo: assignment, now: now))
            #expect(
                ContentItemVisibility.isVisibleToStudents(
                    item, attachedTo: assignment, studentCanSubmit: true, now: now))
            item.isPublished = false
            #expect(
                !ContentItemVisibility.isVisibleToStudents(
                    item, attachedTo: assignment, studentCanSubmit: true, now: now))
        }
    }

    @Test func attachedItemWithoutItsAssignmentIsHidden() async throws {
        try await withApp(app) { _ in
            let item = APICourseContentItem(
                courseID: UUID(), sortOrder: 1, title: "Slides", isPublished: true, assignmentID: UUID())
            #expect(!ContentItemVisibility.isVisibleToStudents(item, attachedTo: nil))
        }
    }

    // MARK: - The student course page and the file route

    /// A lab in an auto-enrol course with its slides attached: a link and one
    /// hosted PDF. Returns the lab, the item and the attachment id.
    private func makeLabWithSlides(
        code: String, setupID: String, isOpen: Bool
    ) async throws -> (lab: APIAssignment, item: APICourseContentItem, attachmentID: UUID) {
        let course = try await makeTestCourse(on: app, code: code, mode: .auto)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let lab = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "VisLab",
            dueAt: Date().addingTimeInterval(86_400), isOpen: isOpen)
        let item = APICourseContentItem(
            courseID: courseID, sortOrder: 2, title: "VisSlides", kind: .slides,
            links: [ContentLink(label: "Slides", url: "https://example.com/vis-slides.pdf")],
            assignmentID: try lab.requireID())
        try await item.save(on: app.db)
        let attachment = try await ContentAttachmentStore.store(
            bytes: Data("%PDF-1.4 vis".utf8), originalName: "vis.pdf", label: nil, sortOrder: 1,
            itemID: try item.requireID(), on: makeTestRequest(on: app))
        item.attachments = [attachment]
        try await item.save(on: app.db)
        return (lab, item, attachment.id)
    }

    @Test func openLabShowsItsSlidesOnTheLabRow() async throws {
        try await withApp(app) { _ in
            _ = try await makeLabWithSlides(code: "MV_OPEN", setupID: "mv_open", isOpen: true)
            let cookie = try await loginUser(username: "mv_open_student", password: "pw", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("VisLab"))
                    // The slides' link is a button on the lab row...
                    #expect(html.contains("https://example.com/vis-slides.pdf"))
                    // ...and the slides are not a row of their own.
                    #expect(!html.contains(#"<div class="item-title">VisSlides"#))
                })
        }
    }

    @Test func closedLabHidesItsSlidesAndTheirFiles() async throws {
        try await withApp(app) { _ in
            let (_, item, attachmentID) = try await makeLabWithSlides(
                code: "MV_CLOSED", setupID: "mv_closed", isOpen: false)
            let itemID = try item.requireID()
            let cookie = try await loginUser(
                username: "mv_closed_student", password: "pw", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("https://example.com/vis-slides.pdf"))
                })
            try await app.asyncTest(
                .GET, "/content-files/\(itemID)/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .notFound) })

            // Staff reach the file before the lab opens.
            let staffCookie = try await loginUser(
                username: "mv_closed_staff", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("mv_closed_staff", on: app)
            try await app.asyncTest(
                .GET, "/content-files/\(itemID)/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffCookie) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }

    @Test func studentWithAnExtensionSeesTheSlidesOfAClosedLab() async throws {
        try await withApp(app) { _ in
            // Closed before its deadline: hidden by state, but this student
            // holds an extension and can still complete the lab.
            let (lab, item, attachmentID) = try await makeLabWithSlides(
                code: "MV_EXT", setupID: "mv_ext", isOpen: false)
            let cookie = try await loginUser(username: "mv_ext_student", password: "pw", role: "student", on: app)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "mv_ext_student").first())
            try await APIAssignmentExtension(
                assignmentID: try lab.requireID(), userID: try student.requireID(),
                extendedDueAt: Date().addingTimeInterval(3 * 86_400)
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("https://example.com/vis-slides.pdf"))
                })
            try await app.asyncTest(
                .GET, "/content-files/\(try item.requireID())/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }

    @Test func openLabServesItsSlidesFilesToStudents() async throws {
        try await withApp(app) { _ in
            let (_, item, attachmentID) = try await makeLabWithSlides(
                code: "MV_FILE", setupID: "mv_file", isOpen: true)
            let cookie = try await loginUser(username: "mv_file_student", password: "pw", role: "student", on: app)
            try await app.asyncTest(
                .GET, "/content-files/\(try item.requireID())/\(attachmentID)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }
}

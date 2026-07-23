// Tests/APITests/ContentItemRoutesTests.swift
//
// Integration tests for CourseAdminRoutes+ContentItems (ungraded content
// items shown inside course sections) plus their dashboard rendering:
//   POST /instructor/content-items              — create
//   POST /instructor/content-items/:id/edit     — update
//   POST /instructor/content-items/:id/delete   — delete
//   GET  /                                       — student dashboard (published only)
//   GET  /instructor                             — instructor dashboard (all items)

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ContentItemRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-content")
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCourse(code: String) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return course
    }

    @discardableResult
    private func makeSection(
        name: String, order: Int = 1, courseID: UUID
    ) async throws
        -> APICourseSection
    {
        let section = APICourseSection(
            name: name, defaultGradingMode: "worker", sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    @discardableResult
    private func makeContentItem(
        title: String, courseID: UUID, sectionID: UUID? = nil,
        isPublished: Bool = true, order: Int = 1
    ) async throws -> APICourseContentItem {
        let item = APICourseContentItem(
            courseID: courseID, sectionID: sectionID, sortOrder: order, title: title,
            kind: .link, links: [ContentLink(label: "Site", url: "https://example.com")],
            isPublished: isPublished)
        try await item.save(on: app.db)
        return item
    }

    /// Form body for creating a content item (link arrays + csrf).
    private struct CreateBody: Content {
        var title: String
        var kind: String
        var linkLabels: [String]
        var linkURLs: [String]
        var description: String
        var updatedLabel: String
        var sectionID: String
        var isPublished: String
        var csrf: String
        enum CodingKeys: String, CodingKey {
            case title, kind, linkLabels, linkURLs, description, updatedLabel, sectionID, isPublished
            case csrf = "_csrf"
        }
    }

    // MARK: - Create

    @Test func createContentItem_persistsWithLinks() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_CREATE1")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Lectures", courseID: courseID)
            let cookie = try await loginUser(
                username: "ci_instr1", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_instr1", on: app)
            let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        CreateBody(
                            title: "Lecture 1", kind: "notebook",
                            linkLabels: ["PDF", "Notebook"],
                            linkURLs: ["https://example.com/l1.pdf", "/materials/l1.ipynb"],
                            description: "Intro", updatedLabel: "2026-05-11",
                            sectionID: section.requireID().uuidString, isPublished: "true",
                            csrf: token),
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            let items = try await APICourseContentItem.query(on: app.db)
                .filter(\.$courseID == courseID).all()
            #expect(items.count == 1)
            let item = try #require(items.first)
            #expect(item.title == "Lecture 1")
            #expect(item.kind == .notebook)
            #expect(item.links.count == 2)
            #expect(item.links.first?.label == "PDF")
            #expect(item.sectionID == section.id)
        }
    }

    @Test func createContentItem_emptyTitleRejected() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_CREATE2")
            let cookie = try await loginUser(
                username: "ci_instr2", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_instr2", on: app)
            let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        CreateBody(
                            title: "   ", kind: "link", linkLabels: [], linkURLs: [],
                            description: "", updatedLabel: "", sectionID: "", isPublished: "true",
                            csrf: token),
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .badRequest) })
            _ = course
        }
    }

    @Test func createContentItem_unsafeURLRejected() async throws {
        try await withApp(app) { _ in
            _ = try await makeCourse(code: "CI_CREATE3")
            let cookie = try await loginUser(
                username: "ci_instr3", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_instr3", on: app)
            let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        CreateBody(
                            title: "Bad", kind: "link", linkLabels: ["x"],
                            linkURLs: ["javascript:alert(1)"], description: "", updatedLabel: "",
                            sectionID: "", isPublished: "true", csrf: token),
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .badRequest) })
        }
    }

    @Test func createContentItem_studentForbidden() async throws {
        try await withApp(app) { _ in
            _ = try await makeCourse(code: "CI_STUDENT")
            let cookie = try await loginUser(
                username: "ci_student", password: "pw", role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        CreateBody(
                            title: "Nope", kind: "link", linkLabels: [], linkURLs: [],
                            description: "", updatedLabel: "", sectionID: "", isPublished: "true",
                            csrf: token),
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther || res.status == .forbidden)
                })
        }
    }

    // MARK: - Edit / delete

    @Test func editContentItem_updatesFields() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_EDIT")
            let courseID = try course.requireID()
            let item = try await makeContentItem(title: "Old", courseID: courseID)
            let cookie = try await loginUser(
                username: "ci_edit", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_edit", on: app)
            let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items/\(item.requireID().uuidString)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        CreateBody(
                            title: "New", kind: "slides", linkLabels: ["Deck"],
                            linkURLs: ["https://example.com/d.pdf"], description: "", updatedLabel: "",
                            sectionID: "", isPublished: "false", csrf: token),
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            let updated = try #require(try await APICourseContentItem.find(item.id, on: app.db))
            #expect(updated.title == "New")
            #expect(updated.kind == .slides)
            #expect(updated.isPublished == false)
        }
    }

    @Test func deleteContentItem_removesIt() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_DELETE")
            let courseID = try course.requireID()
            let item = try await makeContentItem(title: "Doomed", courseID: courseID)
            let cookie = try await loginUser(
                username: "ci_del", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_del", on: app)
            let (token, newCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/content-items/\(item.requireID().uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            #expect(try await APICourseContentItem.find(item.id, on: app.db) == nil)
        }
    }

    // MARK: - Rendering

    @Test func studentDashboard_showsPublishedHidesDraft() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_RENDER")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Lectures", courseID: courseID)
            let sectionID = try section.requireID()
            try await makeContentItem(
                title: "PublishedLecture", courseID: courseID, sectionID: sectionID,
                isPublished: true, order: 1)
            try await makeContentItem(
                title: "DraftLecture", courseID: courseID, sectionID: sectionID,
                isPublished: false, order: 2)

            // A student auto-enrolls on login into the .auto course.
            let cookie = try await loginUser(
                username: "ci_viewer", password: "pw", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("PublishedLecture"))
                    #expect(!body.contains("DraftLecture"))
                    // Content-only section still renders its heading.
                    #expect(body.contains("Lectures"))
                })
        }
    }

    @Test func instructorDashboard_showsAllItems() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CI_RENDER_INSTR")
            let courseID = try course.requireID()
            let section = try await makeSection(name: "Lectures", courseID: courseID)
            let sectionID = try section.requireID()
            try await makeContentItem(
                title: "PubItem", courseID: courseID, sectionID: sectionID, isPublished: true)
            try await makeContentItem(
                title: "DraftItem", courseID: courseID, sectionID: sectionID, isPublished: false,
                order: 2)

            let cookie = try await loginUser(
                username: "ci_instr_view", password: "pw", role: "instructor", on: app)
            try await promoteToInstructor("ci_instr_view", on: app)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("PubItem"))
                    #expect(body.contains("DraftItem"))  // staff see drafts too
                })
        }
    }
}

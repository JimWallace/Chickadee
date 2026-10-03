// Tests/APITests/AdminCoursePageTests.swift
//
// The admin course page as redesigned in #1974: one fields partial for the
// three course forms, the settings shown as facts with an edit panel that
// opens on demand, and every destructive action in a ⋯ menu.

import Core
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class AdminCoursePageTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-course-page")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "course_page_admin", password: "testpassword", role: "admin", on: app)
    }

    private func getHTML(_ path: String, cookie: String) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    /// A course in Fall 2026, its page path, and an admin's session cookie.
    private func termCoursePage() async throws -> (path: String, cookie: String) {
        let cookie = try await loginAsAdmin()
        let course = APICourse(code: "PAGE101", name: "Pages", term: AcademicTerm(year: 2026, season: .fall))
        try await course.save(on: app.db)
        return ("/admin/courses/\(try course.requireID().uuidString)", cookie)
    }

    /// The opening tag of the element with `id`, so a test can read its class.
    private func openingTag(withID id: String, in html: String) throws -> String {
        let marker = "id=\"\(id)\""
        let markerRange = try #require(html.range(of: marker))
        let tagStart = try #require(html[..<markerRange.lowerBound].lastIndex(of: "<"))
        let tagEnd = try #require(html[markerRange.upperBound...].firstIndex(of: ">"))
        return String(html[tagStart...tagEnd])
    }

    @Test func settingsAreFactsAndTheirFormsStartClosed() async throws {
        try await withApp(app) { _ in
            let (path, cookie) = try await termCoursePage()
            let html = try await getHTML(path, cookie: cookie)
            #expect(html.contains("<dl class=\"detail-grid\">"))
            #expect(html.contains("<dt>Term</dt>"))
            #expect(html.contains("Fall 2026"))
            #expect(try openingTag(withID: "course-settings-panel", in: html).contains("class=\"add-panel card\""))
            #expect(try openingTag(withID: "clone-course", in: html).contains("class=\"add-panel card\""))
        }
    }

    @Test func aCourseWithNoTermSaysSo() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "PAGE102")
            let html = try await getHTML("/admin/courses/\(try course.requireID().uuidString)", cookie: cookie)
            #expect(html.contains("None recorded"))
        }
    }

    @Test func aSettingsErrorOpensOnlyTheSettingsPanel() async throws {
        try await withApp(app) { _ in
            let (path, cookie) = try await termCoursePage()
            let html = try await getHTML(path + "?error=\(CourseFormError.codeTaken.rawValue)", cookie: cookie)
            #expect(try openingTag(withID: "course-settings-panel", in: html).contains("is-open"))
            #expect(try openingTag(withID: "clone-course", in: html).contains("is-open") == false)
            #expect(html.contains(CourseFormError.codeTaken.message))
        }
    }

    @Test func aCloneErrorOpensOnlyTheClonePanel() async throws {
        try await withApp(app) { _ in
            let (path, cookie) = try await termCoursePage()
            let html = try await getHTML(path + "?error=\(CourseCloneFormError.codeTaken.rawValue)", cookie: cookie)
            #expect(try openingTag(withID: "clone-course", in: html).contains("is-open"))
            #expect(try openingTag(withID: "course-settings-panel", in: html).contains("is-open") == false)
            #expect(html.contains(CourseCloneFormError.codeTaken.message))
            #expect(!html.contains(CourseFormError.codeTaken.message))
        }
    }

    @Test func eachCourseFormHasItsOwnFieldIDs() async throws {
        try await withApp(app) { _ in
            let (path, cookie) = try await termCoursePage()
            let html = try await getHTML(path, cookie: cookie)
            for id in ["course-settings-code", "course-settings-term", "clone-code", "clone-term"] {
                #expect(html.components(separatedBy: "id=\"\(id)\"").count == 2, "\(id) appears once")
            }
            let newHTML = try await getHTML("/admin/courses/new", cookie: cookie)
            #expect(newHTML.contains("id=\"new-course-code\""))
            #expect(newHTML.contains("autofocus"))
        }
    }

    @Test func destructiveActionsSitInMenus() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "PAGE103")
            let courseID = try course.requireID()
            let student = try await makeTestUser(on: app, username: "page_student", role: "student")
            try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)
            let html = try await getHTML("/admin/courses/\(courseID.uuidString)", cookie: cookie)

            // Archive and Remove are menu items, each behind a confirmation.
            for action in ["/archive", "/unenroll/\(try student.requireID().uuidString)"] {
                let form = try #require(html.range(of: "action=\"/admin/courses/\(courseID.uuidString)\(action)\""))
                let menu = try #require(html[..<form.lowerBound].range(of: "row-menu-panel", options: .backwards))
                #expect(!html[menu.upperBound..<form.lowerBound].contains("</details>"), "\(action) is inside a menu")
                #expect(html[form.upperBound...].prefix(400).contains("data-confirm="))
                #expect(html[form.upperBound...].prefix(600).contains("row-menu-item--danger"))
            }
        }
    }

    @Test func theRosterShowsEachPersonsAvatar() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "PAGE104")
            let courseID = try course.requireID()
            let student = try await makeTestUser(on: app, username: "page_avatar", role: "student")
            try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)
            let html = try await getHTML("/admin/courses/\(courseID.uuidString)", cookie: cookie)
            let cell = try #require(html.range(of: "<td class=\"item-tile-cell\">"))
            let cellEnd = try #require(html[cell.upperBound...].range(of: "</td>"))
            #expect(html[cell.upperBound..<cellEnd.lowerBound].contains("<svg"))
        }
    }
}

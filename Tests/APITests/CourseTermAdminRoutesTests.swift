// Tests/APITests/CourseTermAdminRoutesTests.swift
//
// Slice 2 of docs/course-terms.md: the admin create and edit forms declare a
// course's year and term, the pages render it, the nav shows it, and course
// lists sort newest term first.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseTermAdminRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-course-term")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "term_admin", password: "testpassword", role: "admin", on: app)
    }

    /// Posts a form to `path` with a CSRF token bound to `formPath`, and
    /// returns the redirect location.
    private func post(
        _ path: String, form: [String: String], cookie: String, formPath: String
    ) async throws -> String? {
        let (token, boundCookie) = try await csrfFields(for: formPath, cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = token
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
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

    // MARK: - Create

    @Test func createStoresTheDeclaredTerm() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            _ = try await post(
                "/admin/courses",
                form: ["code": "TRM101", "name": "Terms", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/new")

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "TRM101").first())
            #expect(course.term == AcademicTerm(year: 2026, season: .fall))
        }
    }

    @Test(arguments: [
        [String: String](),
        ["termYear": "2026"],
        ["termSeason": "fall"],
        ["termYear": "26", "termSeason": "fall"],
        ["termYear": "2026", "termSeason": "autumn"],
    ])
    func createRefusesAMissingOrInvalidTerm(termFields: [String: String]) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            var form = ["code": "TRM102", "name": "Terms"]
            form.merge(termFields) { _, new in new }
            let location = try await post(
                "/admin/courses", form: form, cookie: cookie, formPath: "/admin/courses/new")

            #expect(location == "/admin/courses/new?error=course_term_required")
            let created = try await APICourse.query(on: app.db).filter(\.$code == "TRM102").count()
            #expect(created == 0)
        }
    }

    @Test func createRefusesAnActiveDuplicateCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            try await makeTestCourse(on: app, code: "TRM103")
            let location = try await post(
                "/admin/courses",
                form: ["code": "TRM103", "name": "Again", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie, formPath: "/admin/courses/new")

            #expect(location == "/admin/courses/new?error=code_taken")
            let count = try await APICourse.query(on: app.db).filter(\.$code == "TRM103").count()
            #expect(count == 1)
        }
    }

    @Test func newCourseFormOffersTheThreeTermsAndShowsTheTermError() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let html = try await getHTML("/admin/courses/new?error=course_term_required", cookie: cookie)
            #expect(html.contains("name=\"termYear\""))
            #expect(html.contains("<option value=\"winter\""))
            #expect(html.contains("<option value=\"spring\""))
            #expect(html.contains("<option value=\"fall\""))
            #expect(html.contains("Enter a four-digit year and a term."))
            // The suggestion (the term that contains today) is preselected.
            let suggested = try #require(CourseTermForm.suggestion())
            #expect(html.contains("value=\"\(suggested.year)\""))
            #expect(html.contains("<option value=\"\(suggested.season.rawValue)\" selected"))
        }
    }

    // MARK: - Edit

    @Test func editSetsTheTermOfACourseThatHasNone() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "TRM201")
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "TRM201", "name": "Terms", "termYear": "2027", "termSeason": "spring"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.term == AcademicTerm(year: 2027, season: .spring))
        }
    }

    @Test func editWithAnInvalidTermChangesNothing() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            let course = APICourse(
                code: "TRM202", name: "Terms", term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "TRM202-NEW", "name": "Renamed", "termYear": "", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=course_term_required")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.code == "TRM202")
            #expect(stored.term == AcademicTerm(year: 2026, season: .fall))
        }
    }

    @Test func courseDetailShowsTheTermAndTheCodeTakenError() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = APICourse(
                code: "TRM203", name: "Terms", term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let html = try await getHTML("/admin/courses/\(id)?error=code_taken", cookie: cookie)
            #expect(html.contains("TRM203 Fall 2026 — Terms"))
            #expect(html.contains("value=\"2026\""))
            #expect(html.contains("<option value=\"fall\" selected"))
            #expect(html.contains("Another course already uses this code."))
            #expect(!html.contains(">Choose</option>"))
        }
    }

    @Test func courseDetailWithoutATermAsksForOne() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let course = try await makeTestCourse(on: app, code: "TRM204")
            let html = try await getHTML("/admin/courses/\(try course.requireID().uuidString)", cookie: cookie)
            #expect(html.contains(">Choose</option>"))
            #expect(!html.contains("<option value=\"fall\" selected"))
        }
    }

    // MARK: - Lists and nav

    @Test func adminCoursesTableShowsTheTerm() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let term = try #require(AcademicTerm(year: 2027, season: .winter))
            try await APICourse(code: "TRM301", name: "Terms", term: term).save(on: app.db)
            let html = try await getHTML("/admin", cookie: cookie)
            #expect(html.contains("data-sort-value=\"\(term.ordinal)\">Winter 2027</td>"))
        }
    }

    @Test func courseTabsShowTheShortTermAndSortNewestFirst() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "term_student", password: "pw", role: "user", on: app)
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "term_student").first())
            let older = APICourse(code: "TRM401", name: "Old", term: AcademicTerm(year: 2026, season: .spring))
            let newer = APICourse(code: "TRM402", name: "New", term: AcademicTerm(year: 2026, season: .fall))
            for course in [older, newer] {
                try await course.save(on: app.db)
                try await APICourseEnrollment(
                    userID: try user.requireID(), courseID: try course.requireID(), role: .student
                ).save(on: app.db)
            }

            let html = try await getHTML("/", cookie: cookie)
            let newTab = try #require(html.range(of: "TRM402 F26"))
            let oldTab = try #require(html.range(of: "TRM401 S26"))
            #expect(newTab.lowerBound < oldTab.lowerBound)
        }
    }

    // MARK: - Bundle

    /// Exports `source`, archives it so its code is free, imports the bundle,
    /// and returns the imported course and the result page.
    private func exportArchiveAndImport(
        _ source: APICourse, cookie: String
    ) async throws -> (course: APICourse, html: String) {
        let sourceID = try source.requireID()
        var zipData = Data()
        try await app.asyncTest(
            .GET, "/admin/courses/\(sourceID.uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                zipData = Data(res.body.readableBytesView)
            })

        source.isArchived = true
        try await source.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "term-boundary-\(UUID().uuidString)"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(csrf)\r\n")
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zipData)
        body.writeString("\r\n--\(boundary)--\r\n")
        var html = ""
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = body
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })

        let imported = try #require(
            try await APICourse.query(on: app.db)
                .filter(\.$code == source.code)
                .filter(\.$isArchived == false)
                .first())
        #expect(imported.id != sourceID)
        return (imported, html)
    }

    @Test func bundleExportAndImportCarryTheTerm() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            let term = try #require(AcademicTerm(year: 2026, season: .fall))
            let source = APICourse(code: "TRM501", name: "Bundled", term: term)
            try await source.save(on: app.db)

            let (imported, html) = try await exportArchiveAndImport(source, cookie: cookie)
            #expect(imported.term == term)
            #expect(html.contains("TRM501 Fall 2026 — Bundled"))
            #expect(!html.contains("The bundle has no year and term."))
        }
    }

    @Test func importOfABundleWithoutATermAsksForOne() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            let source = APICourse(code: "TRM502", name: "Legacy")
            try await source.save(on: app.db)

            let (imported, html) = try await exportArchiveAndImport(source, cookie: cookie)
            #expect(imported.term == nil)
            #expect(html.contains("The bundle has no year and term."))
            #expect(html.contains("href=\"/admin/courses/\(try imported.requireID().uuidString)\">course page</a>"))
        }
    }
}

/// The pure ordering rule behind every course list; no app needed.
@Suite struct CourseListOrderTests {
    @Test func courseListOrderIsNewestTermFirstThenUntermedThenCode() throws {
        let fall = APICourse(code: "B", name: "", term: AcademicTerm(year: 2026, season: .fall))
        let spring = APICourse(code: "A", name: "", term: AcademicTerm(year: 2026, season: .spring))
        let fallSibling = APICourse(code: "A", name: "", term: AcademicTerm(year: 2026, season: .fall))
        let untermedA = APICourse(code: "A", name: "")
        let untermedC = APICourse(code: "C", name: "")
        let sorted = [untermedC, spring, fall, untermedA, fallSibling].sorted(by: courseListPrecedes)
        #expect(sorted.map(\.code) == ["A", "B", "A", "A", "C"])
        #expect(sorted.map(\.term?.shortLabel) == ["F26", "F26", "S26", nil, nil])
    }
}

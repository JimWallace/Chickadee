// Tests/APITests/Courses/CourseCodeDoorTests.swift
//
// The course-code rules at the doors that `ReservedCourseKeysTests` does not
// reach (the instructor new-term clone, bundle import and the one-click copy),
// and the syntax rule: a code is a URL path segment, so a code with "/", "?",
// "#" or "%" gets no links (`CourseCodeSyntax`).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseCodeDoorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-course-code-doors")
    }

    /// Posts a form to `path` with a CSRF token bound to `formPath`.
    private func post(
        _ path: String, form: [String: String], cookie: String, formPath: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, boundCookie) = try await csrfFields(for: formPath, cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = token
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in result = (res.status, res.headers.first(name: .location)) })
        return result
    }

    private func activeCount(code: String) async throws -> Int {
        try await APICourse.query(on: app.db)
            .filter(\.$code == code).filter(\.$isArchived == false).count()
    }

    /// An instructor of a Fall 2026 course, logged in and active in it.
    private func instructor(_ username: String) async throws -> String {
        let course = APICourse(code: "CCD135", name: "Source", term: AcademicTerm(year: 2026, season: .fall))
        try await course.save(on: app.db)
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
        ).save(on: app.db)
        return cookie
    }

    /// Exports `source`, archives it, and posts the bundle to the import
    /// route. Returns the import response.
    private func exportAndImport(_ source: APICourse, cookie: String) async throws -> (HTTPStatus, String) {
        var zipData = Data()
        try await app.asyncTest(
            .GET, "/admin/courses/\(try source.requireID().uuidString)/export",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                zipData = Data(res.body.readableBytesView)
            })
        source.isArchived = true
        try await source.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
        let boundary = "code-boundary-\(UUID().uuidString)"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(csrf)\r\n")
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bundle.zip\"\r\n")
        body.writeString("Content-Type: application/zip\r\n\r\n")
        body.writeBytes(zipData)
        body.writeString("\r\n--\(boundary)--\r\n")
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .POST, "/admin/courses/import",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = body
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    // MARK: - The premise

    /// A space reaches the course: the browser encodes it, and RoutingKit
    /// decodes each parameter. A "/" does not: the path is split on "/" first,
    /// so the code becomes two segments.
    @Test func aSpaceReachesTheCourseButASlashDoesNot() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            for (code, setupID, path) in [
                ("STAT 230", "setup_ccd01", "/STAT%20230"), ("CS/135", "setup_ccd02", "/CS/135"),
            ] {
                let course = try await makeTestCourse(on: app, code: code)
                let courseID = try course.requireID()
                try await makeTestSetup(on: app, id: setupID, courseID: courseID)
                let assignment = try await makeTestAssignment(
                    on: app, testSetupID: setupID, courseID: courseID, title: "Lab 1")
                var location: String?
                try await app.asyncTest(
                    .GET, "\(path)/\(assignment.slug)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in location = res.headers.first(name: .location) })
                let reached = location == "/testsetups/\(setupID)/notebook"
                #expect(reached == (code == "STAT 230"), "\(code)")
            }
        }
    }

    /// A link Chickadee writes encodes the key, so even a legacy course with
    /// a "/" in its code is reached: "%2F" is not split, and RoutingKit
    /// decodes it back.
    @Test func anEncodedLinkReachesALegacyCourseWithASlash() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "CS/135")
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_ccd03", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_ccd03", courseID: courseID, title: "Lab 1")
            let path = VanityURLRoutes.vanityPath(courseCode: course.urlKey, assignmentSlug: assignment.slug)
            #expect(path == "/CS%2F135/\(assignment.slug)")
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_ccd03/notebook")
                })
        }
    }

    // MARK: - Admin doors

    @Test(arguments: ["CS/135", "CS\\135", "CS135?", "CS#1", "50%", ".."])
    func createRefusesACodeALinkCannotCarry(code: String) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let result = try await post(
                "/admin/courses",
                form: ["code": code, "name": "Unsafe", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/new")

            #expect(result.location == "/admin/courses/new?error=code_unsafe")
            #expect(try await activeCount(code: code) == 0)
        }
    }

    @Test func createAcceptsACodeALinkCanCarry() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            _ = try await post(
                "/admin/courses",
                form: ["code": "STAT 230é", "name": "Safe", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/new")
            #expect(try await activeCount(code: "STAT 230é") == 1)
        }
    }

    /// A course that holds an unsafe code from before the rule can still be
    /// edited without a rename; a rename to an unsafe code is refused.
    @Test func editKeepsALegacyCodeButRefusesARenameToOne() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let course = APICourse(code: "CS/135", name: "Old", term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let kept = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "CS/135", "name": "New name", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")
            #expect(kept.location == "/admin/courses/\(id)")

            let renamed = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "CS/136", "name": "New name", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")
            #expect(renamed.location == "/admin/courses/\(id)?error=code_unsafe")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.code == "CS/135")
            #expect(stored.name == "New name")
        }
    }

    /// An archived course is outside the duplicate rule, but a rename still
    /// gets the new-code rules, so un-archive cannot be the first to refuse it.
    @Test func editOfAnArchivedCourseRefusesARenameToAnUnsafeCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let course = APICourse(
                code: "CCD200", name: "Old", isArchived: true, term: AcademicTerm(year: 2025, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let result = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "CCD/200", "name": "Old", "termYear": "2025", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")
            #expect(result.location == "/admin/courses/\(id)?error=code_unsafe")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.code == "CCD200")
        }
    }

    @Test func copyOfACourseWithAnUnsafeCodeAsksForARename() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "CS/135")
            let id = try course.requireID().uuidString
            let result = try await post(
                "/admin/courses/\(id)/copy", form: [:], cookie: cookie, formPath: "/admin/courses/\(id)")
            #expect(result.status == .conflict)
            #expect(try await activeCount(code: "CS/135-COPY") == 0)
        }
    }

    // MARK: - Instructor new term

    @Test(arguments: [("data", "clone_code_reserved"), ("CS#135", "clone_code_unsafe")])
    func newTermRefusesTheCode(code: String, error: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await instructor("ccd_instructor")
            let result = try await post(
                "/instructor/new-term",
                form: ["code": code, "name": "Target", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie, formPath: "/instructor/new-term")
            #expect(result.status == .seeOther)
            #expect(result.location == "/instructor/new-term?error=\(error)")
            #expect(try await activeCount(code: code) == 0)
        }
    }

    // MARK: - Bundle import

    @Test(arguments: [("data", "is a page address on this server"), ("CS/135", "cannot be used in a link")])
    func importRefusesTheCode(code: String, reason: String) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("ccd_admin", on: app)
            let source = APICourse(code: code, name: "Legacy", term: AcademicTerm(year: 2026, season: .fall))
            try await source.save(on: app.db)
            let (status, body) = try await exportAndImport(source, cookie: cookie)

            #expect(status == .conflict)
            #expect(body.contains(reason))
            #expect(try await activeCount(code: code) == 0)
        }
    }

    // MARK: - The health rule

    @Test func theRuleReportsActiveCoursesWithAnUnsafeCode() async throws {
        try await withApp(app) { app in
            try await makeTestCourse(on: app, code: "CS?135", archived: true)
            #expect(!(try await evaluateCourseCodeNotURLSafe(on: app)).isFiring)
            try await makeTestCourse(on: app, code: "CS/135")
            try await makeTestCourse(on: app, code: "STAT 230")
            let result = try await evaluateCourseCodeNotURLSafe(on: app)
            #expect(result.isFiring)
            #expect(result.details["courses"] == "\"CS/135\"")
            #expect(HealthRule.courseCodeNotURLSafe.severity == "warning")
        }
    }
}

/// The syntax rule on its own: no app.
@Suite struct CourseCodeSyntaxTests {
    @Test(arguments: ["CS135", "cs135", "CS135-F26", "MSCI_100", "STAT.230", "STAT 230", "CSé", "a+b", "a&b"])
    func acceptsASafeCode(code: String) {
        #expect(CourseCodeSyntax.isURLSafe(code))
    }

    @Test(arguments: ["", ".", "..", "CS/135", "CS\\135", "a?b", "a#b", "50%", "a\tb", "a\nb"])
    func refusesACodeALinkCannotCarry(code: String) {
        #expect(!CourseCodeSyntax.isURLSafe(code))
    }
}

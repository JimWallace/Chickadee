// Tests/APITests/Courses/ReservedCourseKeysTests.swift
//
// #2666: a course whose code is the first segment of a fixed route loses its
// vanity links, because the router takes the fixed branch and never
// backtracks. The reserved set is read from the registered routes; every door
// that creates or renames a course refuses a reserved code; and the
// `courseKeyShadowed` health rule reports any active course that holds one.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class ReservedCourseKeysTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reserved-keys")
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

    private func courseCount(code: String) async throws -> Int {
        try await APICourse.query(on: app.db).filter(\.$code == code).count()
    }

    // MARK: - The reserved set

    @Test func theSetHoldsTheFirstSegmentOfEveryFixedRoute() async throws {
        try await withApp(app) { app in
            let reserved = app.reservedCourseKeys
            // The two routes the issue names, one-segment routes, and the
            // JupyterLite contents routes.
            for segment in ["data", "submissions", "login", "admin", "instructor", "lab", "api", "testsetups"] {
                #expect(reserved.segments.contains(segment), "\(segment) should be reserved")
            }
            var expected: Set<String> = []
            for route in app.routes.all {
                if case .constant(let first) = route.path.first { expected.insert(first.lowercased()) }
            }
            #expect(reserved.segments == expected)
            // The vanity routes start with a parameter and reserve nothing.
            #expect(!reserved.segments.contains(":courseCode"))
            #expect(!reserved.reserves(code: "CS135", term: nil))
        }
    }

    /// The premise: a course coded like a fixed route does not get its link.
    @Test func aCourseCodedLikeAFixedRouteLosesItsVanityLink() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "data")
            let courseID = try course.requireID()
            try await APITestSetup(
                id: "setup_reserved01", manifest: "{}",
                zipPath: app.testSetupsDirectory + "setup_reserved01.zip", courseID: courseID
            ).save(on: app.db)
            let assignment = APIAssignment(
                testSetupID: "setup_reserved01", title: "Lab 1", isOpen: true, courseID: courseID)
            try await assignment.save(on: app.db)
            let cookie = try await loginAsAdmin("reserved_admin", on: app)

            try await app.asyncTest(
                .GET, "/data/\(assignment.slug)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) != "/testsetups/setup_reserved01/notebook")
                })
        }
    }

    // MARK: - The doors

    @Test(arguments: ["data", "Lab", "LOGIN", "submissions"])
    func createRefusesAReservedCode(code: String) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let location = try await post(
                "/admin/courses",
                form: ["code": code, "name": "Reserved", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/new")

            #expect(location == "/admin/courses/new?error=code_reserved")
            #expect(try await courseCount(code: code) == 0)
        }
    }

    @Test func theCreateFormShowsTheReservedMessage() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let html = try await getHTML("/admin/courses/new?error=code_reserved", cookie: cookie, on: app)
            #expect(html.contains("is a page address on this server"))
        }
    }

    @Test func editRefusesARenameToAReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = APICourse(code: "RSV101", name: "Reserved", term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "login", "name": "Reserved", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=code_reserved")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.code == "RSV101")
        }
    }

    /// A course that already holds a reserved code is not trapped: it can be
    /// edited without a rename, and the health rule reports it instead.
    @Test func editKeepsAnExistingReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = APICourse(code: "data", name: "Old", term: AcademicTerm(year: 2026, season: .fall))
            try await course.save(on: app.db)
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "data", "name": "New name", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.name == "New name")
        }
    }

    @Test func unarchiveRefusesAReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "lab", archived: true)
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/archive", form: [:], cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=code_reserved")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.isArchived)
        }
    }

    @Test func cloneRefusesAReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let source = try await makeTestCourse(on: app, code: "RSV201")
            let id = try source.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/clone",
                form: ["code": "api", "name": "Clone", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=clone_code_reserved#clone-course")
            #expect(try await courseCount(code: "api") == 0)
        }
    }

    // MARK: - The health rule

    @Test func theRuleReadsActiveCoursesOnly() async throws {
        try await withApp(app) { app in
            try await makeTestCourse(on: app, code: "data", archived: true)
            #expect(!(try await evaluateCourseKeyShadowed(on: app)).isFiring)
            try await makeTestCourse(on: app, code: "submissions")
            let result = try await evaluateCourseKeyShadowed(on: app)
            #expect(result.isFiring)
            #expect(result.details["courses"] == "submissions")
            #expect(HealthRule.courseKeyShadowed.severity == "warning")
        }
    }
}

/// The checks that need no app: a class suite above owns an app per test, and
/// every test there must run inside `withApp` so that the app shuts down.
@Suite struct ReservedCourseKeysLogicTests {
    @Test func theCheckIgnoresCaseAndCoversTheBareCodeOfATermedCourse() {
        let reserved = ReservedCourseKeys(segments: ["data"])
        #expect(reserved.reserves(code: "DATA", term: nil))
        #expect(reserved.reserves(code: "Data", term: AcademicTerm(year: 2026, season: .fall)))
        #expect(!reserved.reserves(code: "DATA101", term: nil))
        #expect(!ReservedCourseKeys.none.reserves(code: "data", term: nil))
    }

    @Test func theRuleNamesEachShadowedCourse() {
        let reserved = ReservedCourseKeys(segments: ["data", "lab"])
        let courses = [
            APICourse(code: "lab", name: "A"),
            APICourse(code: "CS135", name: "B"),
            APICourse(code: "data", name: "C", term: AcademicTerm(year: 2026, season: .fall)),
        ]
        let result = decideCourseKeyShadowed(courses: courses, reserved: reserved)
        #expect(result.isFiring)
        #expect(result.details["courses"] == "data-F26, lab")
        #expect(!decideCourseKeyShadowed(courses: [courses[1]], reserved: reserved).isFiring)
    }
}

// Tests/APITests/Courses/ReservedCourseKeyTests.swift
//
// #2666: a course whose key is the first segment of a fixed route loses its
// vanity URLs to that route (`/data/<slug>` reaches the Data page). The
// reserved set is read from the live route table (`Routes.reservedCourseKeys`),
// and the course doors refuse a code in it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ReservedCourseKeyTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reserved-key")
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

    @Test func theReservedSetHoldsTheTwoRoutesTheIssueFound() async throws {
        try await withApp(app) { app in
            let reserved = app.routes.reservedCourseKeys
            #expect(reserved.contains("data"))
            #expect(reserved.contains("submissions"))
            #expect(reserved.contains("testsetups"))
            #expect(reserved.contains("admin"))
            // A one-segment route cannot shadow `/:courseCode/:assignmentSlug`.
            #expect(!reserved.contains("login"))
        }
    }

    @Test func everyTwoSegmentFixedGETRouteIsReserved() async throws {
        try await withApp(app) { app in
            let reserved = app.routes.reservedCourseKeys
            for route in app.routes.all where route.method == .GET && route.path.count >= 2 {
                guard case .constant(let first) = route.path[0] else { continue }
                #expect(reserved.contains(first.lowercased()), "\(route.path) is not reserved")
            }
            #expect(courseKeyIsReserved(code: "DATA", term: nil, routes: app.routes))
            #expect(!courseKeyIsReserved(code: "CS135", term: nil, routes: app.routes))
        }
    }

    @Test(arguments: ["data", "Submissions"])
    func createRefusesAReservedCode(code: String) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let location = try await post(
                "/admin/courses",
                form: ["code": code, "name": "Reserved", "termYear": "2026", "termSeason": "fall"],
                cookie: cookie, formPath: "/admin/courses/new")

            #expect(location == "/admin/courses/new?error=\(CourseFormError.codeReserved.rawValue)")
            let created = try await APICourse.query(on: app.db).filter(\.$name == "Reserved").count()
            #expect(created == 0)
        }
    }

    @Test func editRefusesARenameOntoAReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "RSV101")
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "data", "name": "Renamed"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=\(CourseFormError.codeReserved.rawValue)")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.code == "RSV101")
        }
    }

    @Test func aCourseThatAlreadyHoldsAReservedCodeCanStillBeEdited() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "data")
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "data", "name": "Still Here"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.name == "Still Here")
        }
    }

    @Test func aCourseThatAlreadyHoldsAReservedCodeCanBeGivenATerm() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "submissions")
            let id = try course.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/edit",
                form: ["code": "submissions", "name": "Termed", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)")
            let stored = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(stored.term == AcademicTerm(year: 2027, season: .winter))
        }
    }

    @Test func adminCloneRefusesAReservedCode() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("reserved_admin", on: app)
            let source = try await makeTestCourse(on: app, code: "RSV301")
            let id = try source.requireID().uuidString
            let location = try await post(
                "/admin/courses/\(id)/clone",
                form: ["code": "Data", "name": "Cloned", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie, formPath: "/admin/courses/\(id)")

            #expect(location == "/admin/courses/\(id)?error=\(CourseCloneFormError.codeReserved.rawValue)#clone-course")
            let created = try await APICourse.query(on: app.db).filter(\.$name == "Cloned").count()
            #expect(created == 0)
        }
    }

    @Test func eachReservedErrorHasAMessage() {
        #expect(CourseFormError.message(forQuery: "code_reserved") == CourseFormError.reservedCodeMessage)
        #expect(CourseCloneFormError.message(forQuery: "clone_code_reserved") == CourseFormError.reservedCodeMessage)
    }
}

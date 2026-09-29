// Tests/APITests/InstructorNewTermRoutesTests.swift
//
// Slice 5 of docs/course-terms.md: a per-course instructor clones the active
// course into a new term from the instructor "New term" tab, and becomes the
// instructor of the new course. A TA may not.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(10))) final class InstructorNewTermRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-new-term")
    }

    /// A Fall 2026 course with one assignment, and a logged-in member of it
    /// with `role`.
    private func setUp(
        username: String, role: CourseRole
    ) async throws -> (course: APICourse, user: APIUser, cookie: String) {
        let course = APICourse(code: "NT135", name: "New Term Source", term: AcademicTerm(year: 2026, season: .fall))
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "setup_ntsrc1", courseID: courseID)
        try await makeTestAssignment(on: app, testSetupID: "setup_ntsrc1", courseID: courseID, title: "Lab 1")

        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return (course, user, cookie)
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

    private func postClone(
        form: [String: String], cookie: String
    ) async throws -> (status: HTTPStatus, location: String?, cookie: String) {
        let (token, boundCookie) = try await csrfFields(for: "/instructor/new-term", cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = token
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.asyncTest(
            .POST, "/instructor/new-term",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields, as: .urlEncodedForm)
            },
            afterResponse: { res in result = (res.status, res.headers.first(name: .location)) })
        return (result.0, result.1, boundCookie)
    }

    @Test func tabOffersTheNextTerm() async throws {
        try await withApp(app) { _ in
            let (_, _, cookie) = try await setUp(username: "nt_instructor1", role: .instructor)
            let html = try await getHTML("/instructor/new-term", cookie: cookie)
            #expect(html.contains("Clone NT135 Fall 2026 for a new term"))
            #expect(html.contains("action=\"/instructor/new-term\""))
            #expect(html.contains("value=\"2027\""))
            #expect(html.contains("<option value=\"winter\" selected"))
            #expect(html.contains("href=\"/instructor/new-term\" aria-current=\"page\""))
        }
    }

    @Test func instructorClonesAndTeachesTheNewCourse() async throws {
        try await withApp(app) { app in
            let (source, user, cookie) = try await setUp(username: "nt_instructor2", role: .instructor)
            let sourceID = try source.requireID()
            let result = try await postClone(
                form: ["code": "NT135", "name": "New Term Target", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)
            #expect(result.status == .seeOther)
            #expect(result.location == "/instructor/new-term?cloned=1")

            let clone = try #require(
                try await APICourse.query(on: app.db)
                    .filter(\.$code == "NT135").filter(\.$id != sourceID).first())
            let cloneID = try clone.requireID()
            #expect(clone.term == AcademicTerm(year: 2027, season: .winter))
            let assignments = try await APIAssignment.query(on: app.db).filter(\.$courseID == cloneID).count()
            #expect(assignments == 1)

            // The caller, and only the caller, is enrolled, as instructor.
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == cloneID).all()
            #expect(enrollments.map(\.userID) == [try user.requireID()])
            #expect(enrollments.first?.role == .instructor)

            // The new course is now the active one, and the page points to
            // its assignments rather than to a second clone.
            let html = try await getHTML("/instructor/new-term?cloned=1", cookie: result.cookie)
            #expect(html.contains("NT135 Winter 2027 — New Term Target"))
            #expect(html.contains("set the new course&#39;s dates") || html.contains("set the new course's dates"))
            #expect(html.contains("href=\"/instructor\">Open its assignments</a>"))
            #expect(!html.contains("action=\"/instructor/new-term\""))
        }
    }

    @Test(arguments: [
        (["code": "", "name": "X", "termYear": "2027", "termSeason": "winter"], "clone_fields_required"),
        (["code": "NT135", "name": "X", "termYear": "", "termSeason": "winter"], "clone_term_required"),
        (["code": "NT135", "name": "X", "termYear": "2026", "termSeason": "fall"], "clone_code_taken"),
    ])
    func cloneRefusesAnInvalidForm(form: [String: String], error: String) async throws {
        try await withApp(app) { app in
            let (_, _, cookie) = try await setUp(username: "nt_instructor3", role: .instructor)
            let result = try await postClone(form: form, cookie: cookie)
            #expect(result.location == "/instructor/new-term?error=\(error)")
            let count = try await APICourse.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    @Test func aTACannotClone() async throws {
        try await withApp(app) { app in
            let (_, _, cookie) = try await setUp(username: "nt_ta", role: .ta)
            let html = try await getHTML("/instructor/new-term", cookie: cookie)
            #expect(html.contains("Only this course's instructors can clone it."))
            #expect(!html.contains("action=\"/instructor/new-term\""))

            let result = try await postClone(
                form: ["code": "NT135", "name": "X", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)
            #expect(result.status == .forbidden)
            let count = try await APICourse.query(on: app.db).count()
            #expect(count == 1)
        }
    }
}

// Tests/APITests/GitHub/GitHubCourseUnbindTests.swift
//
// `POST /instructor/github/unbind`: removing a course's GitHub organization.
//
// Unbinding is an instructor's decision (#2207). A TA or a student must not be
// able to cut a course off from its organization, and the instructor's unbind
// must remove the binding for the active course only.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class GitHubCourseUnbindTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-github-unbind")
    }

    /// The course routes answer 404 until a GitHub App is registered.
    private func registerApp() async throws {
        try await GitHubTestApp.register(on: app, pem: "unused", writesSecrets: false)
    }

    private func bind(courseID: UUID, orgLogin: String) async throws {
        try await APIGitHubCourseOrganization(
            courseID: courseID, installationID: 55, orgID: 7_000, orgLogin: orgLogin
        ).save(on: app.db)
    }

    private func bindings(courseID: UUID) async throws -> Int {
        try await APIGitHubCourseOrganization.query(on: app.db).filter(\.$courseID == courseID).count()
    }

    /// Signs in `username` enrolled in the shared CS101 course at `role`.
    private func signIn(_ username: String, role: CourseRole) async throws -> (cookie: String, courseID: UUID) {
        let cookie = try await loginAsStudent(username, on: app)
        let course = try await wrMakeCourse(on: app)
        let courseID = try course.requireID()
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return (cookie, courseID)
    }

    /// Makes `courseID` the session's active course; returns the cookie to use next.
    private func activate(courseID: UUID, cookie: String) async throws -> String {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var next = bound
        try await app.asyncTest(
            .POST, "/courses/\(courseID.uuidString)/activate",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                if let set = res.headers.first(name: .setCookie) { next = set }
            })
        return next
    }

    private func unbind(cookie: String) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, "/instructor/github/unbind",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    @Test func anInstructorUnbindsTheActiveCourseOnly() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (cookie, courseID) = try await signIn("gh_instructor", role: .instructor)
            let otherCourseID = try await makeTestCourse(on: app, code: "OTHER1").requireID()
            // The instructor teaches the other course too, so only "active"
            // decides which binding goes.
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "gh_instructor").first())
            try await APICourseEnrollment(
                userID: try instructor.requireID(), courseID: otherCourseID, role: .instructor
            )
            .save(on: app.db)
            try await bind(courseID: courseID, orgLogin: "cs101-org")
            try await bind(courseID: otherCourseID, orgLogin: "other-org")
            let active = try await activate(courseID: otherCourseID, cookie: cookie)

            let response = try await unbind(cookie: active)

            #expect(response.location?.hasPrefix("/instructor/github?ok=") == true)
            #expect(try await bindings(courseID: otherCourseID) == 0, "the active course loses its organization")
            #expect(try await bindings(courseID: courseID) == 1, "the other course keeps its organization")
        }
    }

    @Test(arguments: [CourseRole.ta, CourseRole.student])
    func onlyAnInstructorCanUnbind(role: CourseRole) async throws {
        try await withApp(app) { _ in
            try await registerApp()
            let (cookie, courseID) = try await signIn("gh_\(role.rawValue)", role: role)
            try await bind(courseID: courseID, orgLogin: "cs101-org")

            let response = try await unbind(cookie: cookie)

            #expect(response.status == .forbidden)
            #expect(try await bindings(courseID: courseID) == 1)
        }
    }

    @Test func withNoAppRegisteredUnbindIsNotFound() async throws {
        try await withApp(app) { _ in
            let (cookie, courseID) = try await signIn("gh_noapp", role: .instructor)
            try await bind(courseID: courseID, orgLogin: "cs101-org")

            let response = try await unbind(cookie: cookie)

            #expect(response.status == .notFound)
            #expect(try await bindings(courseID: courseID) == 1)
        }
    }
}

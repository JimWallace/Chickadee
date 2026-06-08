// Tests/APITests/ExtensionCSRFTokenTests.swift
//
// Regression coverage for the "CSRF error when saving an extension" report.
//
// The extension endpoints are correctly CSRF-protected, and the token a page
// embeds at render time stays valid for the life of the session — so the
// happy path works even from a long-open page. The narrow failure mode is a
// submit from a page whose *session was replaced* (e.g. idle-timeout then
// re-login), which yields a stale token.
//
// This pins the happy path: the real course-student-submissions page's own
// extension-form token passes CSRF (scraped from the actual rendered page,
// closing the gap where the older tests pulled a token from /instructor).
// The recoverable error page for the stale-token case is covered against the
// production error middleware in SecurityAndHealthTests
// (`leafErrorMiddlewareRendersRecoverableMessageForCSRFFailures`); the test
// harness here doesn't install LeafErrorMiddleware.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct ExtensionCSRFTokenTests {

    /// Seeds an instructor session, an enrolled student, and a published
    /// assignment; returns the login cookie, the student, and the assignment.
    private func seed(
        on app: Application
    ) async throws -> (cookie: String, student: APIUser, assignment: APIAssignment) {
        let cookie = try await arLoginAsInstructor(on: app)
        let student = try await arInsertStudent(username: "csrf_ext_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        try await arInsertSetup(id: "csrf_ext_setup", on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: "csrf_ext_setup",
            title: "CSRF Ext",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-3_600),
            on: app
        )
        return (cookie, student, assignment)
    }

    private func localInput(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Happy path: the real page's own token works

    @Test func extensionSaveUsingRealPageToken() async throws {
        try await withAssignmentRoutesApp { app in
            let (cookie, student, assignment) = try await seed(on: app)
            let token = try student.requireURLToken()

            var pageToken = ""
            var pageCookie = cookie
            try await app.asyncTest(
                .GET, "/TEST101/students/\(token)/submissions",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    if let c = res.headers.first(name: .setCookie) { pageCookie = c }
                    pageToken = extractCSRFToken(from: res.body.string)
                }
            )
            #expect(pageToken.isEmpty == false, "Extension form must carry a CSRF token")

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(token)/assignments/\(assignment.publicID)/extension",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: pageCookie)
                    try req.content.encode(
                        [
                            "_csrf": pageToken,
                            "extendedDueAt": localInput(Date().addingTimeInterval(86_400)),
                            "note": "x",
                        ],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther, "Real-page token must pass CSRF (got \(res.status))")
                }
            )
        }
    }
}

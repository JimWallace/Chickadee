// Tests/APITests/Courses/ActivateCourseRedirectTargetTests.swift
//
// POST /courses/:courseID/activate follows a caller-supplied `next` only when
// it is a plain server-relative path (`isSafeLocalPath`). A browser reads a
// backslash as a slash, so `/\evil.example` is the same off-site target as
// `//evil.example`; both must fall back, not redirect away from the site.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct ActivateCourseRedirectTargetTests {
    /// One `next` value and the Location the route must answer with. The
    /// request carries no Referer, so a refused target falls back to "/".
    struct Case: Sendable, CustomTestStringConvertible {
        let next: String
        let location: String
        var testDescription: String { "next=\(next)" }
    }

    static let cases: [Case] = [
        Case(next: "/\\evil.example", location: "/"),
        Case(next: "/\\\\evil.example", location: "/"),
        Case(next: "//evil.example", location: "/"),
        Case(next: "https://evil.example", location: "/"),
        // Percent-encoded backslash: the browser does not decode %5C before
        // it resolves the Location, so this stays a same-site path.
        Case(next: "/%5Cevil.example", location: "/%5Cevil.example"),
        Case(next: "/courses/x", location: "/courses/x"),
    ]

    @Test(arguments: cases)
    func activateFollowsOnlyASafeLocalNext(_ testCase: Case) async throws {
        try await withTestApp(prefix: "chickadee-actredir") { app in
            let course = try await makeTestCourse(on: app, code: "ACT_REDIR", mode: .auto)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "act_redir_student", password: "pw", role: "student", on: app)
            let (token, sessionCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/activate",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": token, "next": testCase.next], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == testCase.location)
                })
        }
    }
}

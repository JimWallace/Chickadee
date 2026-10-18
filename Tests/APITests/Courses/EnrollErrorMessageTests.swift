// Tests/APITests/Courses/EnrollErrorMessageTests.swift
//
// POST /enroll with nothing selected redirects to /enroll?error=none_selected.
// The page then says why the student is back on it. No other code shows a
// message.

import Core
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class EnrollErrorMessageTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-enr-err")
    }

    private static let message = "Please select at least one course to continue."

    private func enrollPage(query: String) async throws -> String {
        let cookie = try await loginUser(
            username: "enr_err_student", password: "pw", role: "student", on: app)
        var html = ""
        try await app.asyncTest(
            .GET, "/enroll\(query)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    @Test func theNoneSelectedErrorShowsTheMessage() async throws {
        try await withApp(app) { _ in
            let html = try await enrollPage(query: "?error=none_selected")
            #expect(html.contains(Self.message))
        }
    }

    @Test func aPlainVisitShowsNoMessage() async throws {
        try await withApp(app) { _ in
            let html = try await enrollPage(query: "")
            #expect(!html.contains(Self.message))
        }
    }

    @Test func anUnknownErrorCodeShowsNoMessage() async throws {
        try await withApp(app) { _ in
            let html = try await enrollPage(query: "?error=other")
            #expect(!html.contains(Self.message))
        }
    }
}

// Tests/APITests/Pages/OverviewNoticeFetchTests.swift
//
// The Overview's one-shot session notice survives the background GET that a
// `fetch` makes when it follows the Create & Validate or Save & Validate
// redirect. `multipart-forms.js` posts those forms with `fetch`, which
// follows the 302 to `/instructor` (with `Sec-Fetch-Dest: empty`) and then
// navigates there. Before the fix the background GET took the notice, so the
// page that the instructor saw never showed it.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct OverviewNoticeFetchTests {

    private static let sessionNotice = "Created Fetch Notice Lab. Validation is running."

    /// Signs in an instructor of a fresh course and adds a route that leaves
    /// the session notice, as the Create & Validate redirect does.
    private func prepare(_ app: Application, code: String) async throws -> String {
        let courseID = try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
        let username = "\(code.lowercased())_instructor"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .instructor)
            .save(on: app.db)
        app.get("test-set-overview-notice-fetch") { req -> HTTPStatus in
            req.setOverviewNotice(Self.sessionNotice)
            return .ok
        }
        try await app.asyncTest(
            .GET, "/test-set-overview-notice-fetch",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in #expect(res.status == .ok) })
        return cookie
    }

    /// GETs the Overview with the given `Sec-Fetch-Dest`, or none when nil.
    private func overview(cookie: String, dest: String?, on app: Application) async throws -> String {
        var body = ""
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                if let dest { req.headers.add(name: "Sec-Fetch-Dest", value: dest) }
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                body = res.body.string
            })
        return body
    }

    @Test func aFetchFollowingTheRedirectLeavesTheNoticeForThePage() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice-fetch") { app in
            let cookie = try await prepare(app, code: "ONFETCH")

            let background = try await overview(cookie: cookie, dest: "empty", on: app)
            #expect(!background.contains(Self.sessionNotice), "the fetch does not show the notice")

            let page = try await overview(cookie: cookie, dest: "document", on: app)
            #expect(page.contains(Self.sessionNotice), "the navigation that follows shows it")

            let later = try await overview(cookie: cookie, dest: "document", on: app)
            #expect(!later.contains(Self.sessionNotice), "it shows once")
        }
    }

    @Test func aRequestWithNoFetchMetadataStillReadsTheNotice() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice-fetch") { app in
            let cookie = try await prepare(app, code: "ONNOMETA")

            let page = try await overview(cookie: cookie, dest: nil, on: app)
            #expect(page.contains(Self.sessionNotice))
        }
    }
}

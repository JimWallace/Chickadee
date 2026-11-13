// Tests/APITests/Pages/OverviewNoticeConsumptionTests.swift
//
// The Overview's one-shot session notice (`Request.setOverviewNotice`, set by
// Create & Validate and Save & Validate) is consumed on the next Overview
// render, even when a `?notice=` query value wins that render. Before the fix
// the query value short-circuited the read, so the session notice stayed and
// showed up on a later, unrelated visit.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct OverviewNoticeConsumptionTests {

    private static let sessionNotice = "Saved Notice Lab. Validation is running."
    private static let queryNotice = "QueryNoticeText"

    /// Signs in an instructor of a fresh course and adds a route that leaves
    /// the session notice, as the Save & Validate redirect does.
    private func prepare(_ app: Application, code: String) async throws -> String {
        let courseID = try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
        let username = "\(code.lowercased())_instructor"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .instructor)
            .save(on: app.db)
        app.get("test-set-overview-notice") { req -> HTTPStatus in
            req.setOverviewNotice(Self.sessionNotice)
            return .ok
        }
        return cookie
    }

    private func setNotice(cookie: String, on app: Application) async throws {
        try await app.asyncTest(
            .GET, "/test-set-overview-notice",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in #expect(res.status == .ok) })
    }

    /// The control: with no query value the session notice shows once.
    @Test func theSessionNoticeShowsOnceOnTheNextOverview() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice") { app in
            let cookie = try await prepare(app, code: "ONCTRL")
            try await setNotice(cookie: cookie, on: app)

            let first = try await getHTML("/instructor", cookie: cookie, on: app)
            #expect(first.contains(Self.sessionNotice))
            let second = try await getHTML("/instructor", cookie: cookie, on: app)
            #expect(!second.contains(Self.sessionNotice))
        }
    }

    @Test func aQueryNoticeStillConsumesTheSessionNotice() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice") { app in
            let cookie = try await prepare(app, code: "ONQUERY")
            try await setNotice(cookie: cookie, on: app)

            let withQuery = try await getHTML("/instructor?notice=\(Self.queryNotice)", cookie: cookie, on: app)
            #expect(withQuery.contains(Self.queryNotice), "the query value wins this render")
            #expect(!withQuery.contains(Self.sessionNotice))

            let later = try await getHTML("/instructor", cookie: cookie, on: app)
            #expect(!later.contains(Self.sessionNotice), "the session notice must not reappear later")
        }
    }
}

// Tests/APITests/Pages/OverviewNoticeInPlaceTests.swift
//
// A save from the workbench pane sets no Overview notice (#3040). The pane
// posts through `Public/inplace-forms.js`, follows the redirect with `fetch`
// and reloads itself, so it never shows the Overview. A notice set by that
// save would wait in the session and appear on a later, unrelated Overview
// visit.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct OverviewNoticeInPlaceTests {

    private static let sessionNotice = "Saved In Place Lab. Validation is running."

    /// Signs in an instructor of a fresh course, adds a route that sets the
    /// notice as the save handlers do, and calls it once, with the in-place
    /// header when `inPlace` is true.
    private func setNotice(_ app: Application, code: String, inPlace: Bool) async throws -> String {
        let courseID = try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
        let username = "\(code.lowercased())_instructor"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .instructor)
            .save(on: app.db)
        app.post("test-set-overview-notice-in-place") { req -> HTTPStatus in
            req.setOverviewNotice(Self.sessionNotice)
            return .ok
        }
        try await app.asyncTest(
            .POST, "/test-set-overview-notice-in-place",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                if inPlace { req.headers.add(name: Request.inPlaceSaveHeader, value: "1") }
            },
            afterResponse: { res in #expect(res.status == .ok) })
        return cookie
    }

    private func overviewPage(cookie: String, on app: Application) async throws -> String {
        var body = ""
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.headers.add(name: "Sec-Fetch-Dest", value: "document")
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                body = res.body.string
            })
        return body
    }

    @Test func aWorkbenchPaneSaveLeavesNoNoticeForALaterOverview() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice-inplace") { app in
            let cookie = try await setNotice(app, code: "ONINPLACE", inPlace: true)
            let page = try await overviewPage(cookie: cookie, on: app)
            #expect(!page.contains(Self.sessionNotice))
        }
    }

    @Test func aSaveWithoutTheHeaderStillSetsTheNotice() async throws {
        try await withTestApp(prefix: "chickadee-overview-notice-inplace") { app in
            let cookie = try await setNotice(app, code: "ONPAGE", inPlace: false)
            let page = try await overviewPage(cookie: cookie, on: app)
            #expect(page.contains(Self.sessionNotice))
        }
    }

    /// The script and the server must name the same header, or every pane
    /// save sets a stale notice again with no test failing.
    @Test func theInPlaceScriptSendsTheHeaderTheServerReads() throws {
        let js = try String(contentsOfFile: "Public/inplace-forms.js", encoding: .utf8)
        #expect(js.contains("req.headers['\(Request.inPlaceSaveHeader)'] = '1'"))
    }
}

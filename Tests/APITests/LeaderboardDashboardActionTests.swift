// Tests/APITests/LeaderboardDashboardActionTests.swift
//
// The Leaderboard action in the dashboards' Actions columns. Before it, the
// only ways to a class activity's board were a button on a submission page and
// one on the edit page, so a student who had not yet submitted could not find
// the board at all. A student's row offers it once the board is visible; a
// staff row offers it for every activity, hidden or not; an ordinary
// assignment offers it nowhere.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardDashboardActionTests {

    private func activityManifest(visible: Bool) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .beatTheInstructor, leaderboardVisibility: visible ? .visible : .hidden))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> String {
        var body: String?
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                body = res.body.string
            })
        return try #require(body)
    }

    private func staffCookie(on app: Application) async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    @Test func studentDashboardOffersTheActionOnlyForAVisibleBoard() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_lbv", manifest: try activityManifest(visible: true), on: app)
            try await wrInsertAssignment(testSetupID: "setup_lbv", title: "Visible Race", isOpen: true, on: app)
            try await wrInsertSetup(id: "setup_lbh", manifest: try activityManifest(visible: false), on: app)
            try await wrInsertAssignment(testSetupID: "setup_lbh", title: "Hidden Race", isOpen: true, on: app)

            let html = try await get("/", cookie: cookie, on: app)
            #expect(html.contains("Visible Race"))
            #expect(html.contains("Hidden Race"))
            #expect(html.contains("href=\"/testsetups/setup_lbv/leaderboard\""))
            #expect(!html.contains("/testsetups/setup_lbh/leaderboard"))
        }
    }

    @Test func instructorDashboardOffersTheActionForEveryActivity() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staffCookie(on: app)
            try await wrInsertSetup(id: "setup_lbi", manifest: try activityManifest(visible: false), on: app)
            try await wrInsertAssignment(testSetupID: "setup_lbi", title: "Staff Race", isOpen: false, on: app)
            try await wrInsertSetup(id: "setup_lbp", on: app)
            try await wrInsertAssignment(testSetupID: "setup_lbp", title: "Plain Lab", isOpen: false, on: app)

            let html = try await get("/instructor", cookie: cookie, on: app)
            #expect(html.contains("Staff Race"))
            #expect(html.contains("Plain Lab"))
            #expect(html.contains("href=\"/testsetups/setup_lbi/leaderboard\""))
            #expect(!html.contains("/testsetups/setup_lbp/leaderboard"))
        }
    }
}

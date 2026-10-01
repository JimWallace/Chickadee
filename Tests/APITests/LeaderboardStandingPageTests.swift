// Tests/APITests/LeaderboardStandingPageTests.swift
//
// The ranked-by-metric leaderboard page as a student and as staff read it: the
// viewer's card, the windowed list, the rank column and the staff additions.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardStandingPageTests {

    private func manifest(visible: Bool = true) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .bestMetric, leaderboardVisibility: visible ? .visible : .hidden))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// `metrics.count` ranked students in best-first order; the logged-in
    /// student is placed at `viewerPlace` (0-based) in that list. Returns the
    /// viewer.
    @discardableResult
    private func seedBoard(
        on app: Application, setupID: String, metrics: [Double], viewerPlace: Int?
    ) async throws -> APIUser {
        let setup = try await wrInsertSetup(id: setupID, manifest: try manifest(), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: setup.courseID, title: "Race \(setupID)")
        let viewer = try await wrStudentUser(on: app)
        try await wrEnrollUser(viewer, on: app)
        let start = Date()
        for (index, metric) in metrics.enumerated() {
            let user: APIUser
            if index == viewerPlace {
                user = viewer
            } else {
                user = try await makeTestUser(
                    on: app, username: "\(setupID)_s\(index)", role: "student")
                try await wrEnrollUser(user, on: app)
            }
            try await APILeaderboardEntry(
                testSetupID: setupID, userID: try user.requireID(),
                submissionID: "\(setupID)_\(index)", metric: metric,
                reachedAt: start.addingTimeInterval(Double(index))
            ).save(on: app.db)
        }
        return viewer
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> TestingHTTPResponse {
        var captured: TestingHTTPResponse?
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in captured = res })
        return try #require(captured)
    }

    private func handle(of user: APIUser, on app: Application) async throws -> String {
        let enrollment = try #require(
            try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user.requireID()).first())
        return try #require(enrollment.avatarHandle)
    }

    @Test func aRankedStudentSeesTheirCardWithRankBestAndNextPlace() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let metrics = (0..<20).map { Double(100 - $0) }
            let viewer = try await seedBoard(
                on: app, setupID: "lb_card", metrics: metrics, viewerPlace: 13)
            let html = try await get("/testsetups/lb_card/leaderboard", cookie: cookie, on: app).body.string
            let handle = try await handle(of: viewer, on: app)

            #expect(html.contains("class=\"you-card card\""))
            #expect(html.contains(">14th <small>of 20</small>"))
            #expect(html.contains("Only you and course staff can link \(handle) to you. It stays the same all term."))
            #expect(html.contains("+1 to pass "))
            // One You pill on the card, one on the list row, and never a chip.
            #expect(html.components(separatedBy: ">You<").count == 3)
            #expect(!html.contains(">you<"))
            // The card's bird is the hero size, the rows' the roster size, and
            // the sprite is included once.
            #expect(html.contains("avatar avatar-lg"))
            #expect(html.contains("avatar avatar-md"))
            #expect(html.components(separatedBy: "id=\"av-backdrop\"").count == 2)
        }
    }

    @Test func theListIsAWindowWithFoldedGapsThatLinkToTheFullList() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lb_win", metrics: (0..<31).map { Double(100 - $0) },
                viewerPlace: 13)
            let html = try await get("/testsetups/lb_win/leaderboard", cookie: cookie, on: app).body.string
            #expect(html.contains("8 more · 4–11"))
            #expect(html.contains("15 more below"))
            #expect(html.contains("href=\"/testsetups/lb_win/leaderboard?all=1\""))
            #expect(!html.contains("Show my standing"))
            // Only the window's eight rows, not thirty-one.
            #expect(html.components(separatedBy: "<td class=\"item-status item-grade\">").count - 1 == 8)
        }
    }

    @Test func allOneShowsEveryRowAndTheWayBackAndTheFilter() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lb_all", metrics: (0..<31).map { Double(100 - $0) },
                viewerPlace: 13)
            let html = try await get("/testsetups/lb_all/leaderboard?all=1", cookie: cookie, on: app).body.string
            #expect(html.components(separatedBy: "<td class=\"item-status item-grade\">").count - 1 == 31)
            #expect(html.contains("Show my standing"))
            #expect(html.contains("data-list-filter=\"leaderboard-table\""))
            // The refresh keeps the full list full.
            let page = html.contains("data-poll-url")
            if page { #expect(html.contains("fragment=body&amp;all=1")) }
        }
    }

    @Test func aTiedViewerIsToldWhoReachedTheScoreFirst() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            // Place 1 and 2 tie at 50; the viewer (index 1) reached it second.
            try await seedBoard(
                on: app, setupID: "lb_tie", metrics: [50, 50, 40, 30], viewerPlace: 1)
            let html = try await get("/testsetups/lb_tie/leaderboard", cookie: cookie, on: app).body.string
            #expect(html.contains("Tied 1st"))
            #expect(html.contains(">1=<"))
            #expect(html.contains("Tied · reached it"))
            // Nobody is above a tie for the top, so there is no next place.
            #expect(!html.contains("Next place"))
        }
    }

    @Test func aStudentWithNoSubmissionGetsTheInvitationAndTheTopFive() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lb_none", metrics: (0..<9).map { Double(50 - $0) },
                viewerPlace: nil)
            let html = try await get("/testsetups/lb_none/leaderboard", cookie: cookie, on: app).body.string
            #expect(html.contains("Not on the board yet"))
            #expect(html.contains("href=\"/testsetups/lb_none/submit\""))
            #expect(html.components(separatedBy: "<td class=\"item-status item-grade\">").count - 1 == 5)
            #expect(html.contains("4 more below"))
        }
    }

    @Test func staffSeeEveryRowWithDetailsAndNoYouCard() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lb_staff2", metrics: (0..<10).map { Double(90 - $0) },
                viewerPlace: 2)
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let html = try await get("/testsetups/lb_staff2/leaderboard", cookie: cookie, on: app).body.string
            #expect(!html.contains("you-card card"))
            #expect(html.components(separatedBy: "<td class=\"item-status item-grade\">").count - 1 == 10)
            #expect(html.contains("<code>lb_staff2_s0</code>"))
            #expect(html.contains("0 submissions"))
            #expect(html.contains("href=\"/submissions/lb_staff2_0\""))
            #expect(html.contains("10 ranked"))
            // Ten rows is enough for the filter.
            #expect(html.contains("data-list-filter=\"leaderboard-table\""))
        }
    }

    @Test func aStudentPageHoldsNoUsernameOrSubmissionCount() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedBoard(
                on: app, setupID: "lb_priv", metrics: [9, 8, 7], viewerPlace: 1)
            let html = try await get("/testsetups/lb_priv/leaderboard", cookie: cookie, on: app).body.string
            #expect(!html.contains("lb_priv_s0"))
            #expect(!html.contains("submissions ·"))
            #expect(!html.contains("/submissions/lb_priv_"))
            #expect(!html.contains("data-list-filter"))
        }
    }

    @Test func theVisibilitySelectPostsBackToTheLeaderboard() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            try await seedBoard(on: app, setupID: "lb_vis2", metrics: [3, 2], viewerPlace: 0)
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let html = try await get("/testsetups/lb_vis2/leaderboard", cookie: cookie, on: app).body.string
            #expect(html.contains("name=\"visibility\""))
            #expect(html.contains("name=\"returnTo\" value=\"/testsetups/lb_vis2/leaderboard\""))
            #expect(html.contains("<option value=\"visible\" selected>Visible to students</option>"))
        }
    }
}

// Tests/APITests/Gamification/LeaderboardLiveRefreshTests.swift
//
// The leaderboard page refreshes its results region during a live session
// (docs/class-activities.md). The region carries the poll attributes, but
// only `table-poll.js` reads them, and the base layout does not load it, so
// the page must load it whenever the region polls. A live board also grows
// during the session, so it shows its filter box however short it is.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardLiveRefreshTests {

    private func render(_ board: LeaderboardPresentation) -> String {
        LeaderboardPage(page: ElementaryPageFixtures.page(), board: board).render()
    }

    @Test func aLiveBoardLoadsThePoller() {
        let html = render(
            LeaderboardSamples.board(.metric, isStaff: true, live: true, sessionWindow: LeaderboardSamples.window))
        #expect(html.contains("data-poll-swap=\"region\""))
        #expect(html.contains("/table-poll.js"))
    }

    @Test func aBoardThatDoesNotPollLoadsNoPoller() {
        let html = render(LeaderboardSamples.board(.metric, isStaff: true))
        #expect(!html.contains("data-poll-url"))
        #expect(!html.contains("/table-poll.js"))
    }

    /// A board in a live session shows its filter box from the first row,
    /// because the class arrives while it is open.
    @Test func aLiveBoardShowsTheFilterBoxBelowTheThreshold() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()),
                on: app)
            let window = LiveSessionWindow(
                opensAt: Date(timeIntervalSinceNow: -60), closesAt: Date(timeIntervalSinceNow: 3_600))
            for (id, activity) in [
                ("setup_live", ClassActivity(kind: .bestMetric, window: window)),
                ("setup_still", ClassActivity(kind: .bestMetric)),
            ] {
                let props = TestProperties(
                    testSuites: [TestSuiteEntry(tier: .pub, script: "m.sh")], language: nil, activity: activity)
                let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
                try await wrInsertSetup(id: id, manifest: manifest, on: app)
                try await wrInsertAssignment(testSetupID: id, title: "Lab \(id)", isOpen: true, on: app)
            }
            for (id, live) in [("setup_live", true), ("setup_still", false)] {
                try await app.asyncTest(
                    .GET, "/testsetups/\(id)/leaderboard",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        #expect(res.status == .ok)
                        #expect(res.body.string.contains("id=\"leaderboard-filter\"") == live, "\(id)")
                        #expect(res.body.string.contains("/table-poll.js") == live, "\(id)")
                    })
            }
        }
    }
}

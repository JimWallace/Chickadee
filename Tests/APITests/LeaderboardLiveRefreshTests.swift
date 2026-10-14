// Tests/APITests/LeaderboardLiveRefreshTests.swift
//
// The leaderboard page refreshes its results region during a live session
// (docs/class-activities.md). The region carries the poll attributes, but
// only `table-poll.js` reads them, and the base layout does not load it, so
// the page must load it whenever the region polls.

import Testing

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
}

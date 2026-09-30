// Tests/APITests/LeaderboardWindowTests.swift
//
// The pure rules behind the leaderboard list: which rows a student sees, how a
// rank is worded, and how far the next place is.

import Testing

@testable import APIServer

@Suite struct LeaderboardWindowTests {

    /// Ranks 1...count with no ties.
    private func plain(_ count: Int) -> [Int] { Array(1...count) }

    private func shownRanks(_ ranks: [Int], viewer: Int?) -> [Int] {
        LeaderboardWindow.slots(ranks: ranks, viewerIndex: viewer).compactMap {
            if case .row(let index) = $0 { return ranks[index] }
            return nil
        }
    }

    @Test func aViewerAtTheTopSeesTheTopAndAFoldedRest() {
        let slots = LeaderboardWindow.slots(ranks: plain(31), viewerIndex: 0)
        #expect(slots.first == .row(0))
        // Places 1 to 3 (which include the viewer's neighbours) then one fold.
        #expect(slots.last == .gap(count: 28, lowRank: 4, highRank: 31, isTrailing: true))
        #expect(slots.count == 4)
    }

    @Test func aViewerInTheTopFiveHasNoLeadingGap() {
        let slots = LeaderboardWindow.slots(ranks: plain(31), viewerIndex: 3)
        #expect(shownRanks(plain(31), viewer: 3) == [1, 2, 3, 4, 5, 6])
        #expect(slots.last == .gap(count: 25, lowRank: 7, highRank: 31, isTrailing: true))
    }

    @Test func aViewerInTheMiddleSeesTwoPlacesEitherSide() {
        let ranks = plain(31)
        let slots = LeaderboardWindow.slots(ranks: ranks, viewerIndex: 13)
        #expect(shownRanks(ranks, viewer: 13) == [1, 2, 3, 12, 13, 14, 15, 16])
        #expect(slots.contains(.gap(count: 8, lowRank: 4, highRank: 11, isTrailing: false)))
        #expect(slots.last == .gap(count: 15, lowRank: 17, highRank: 31, isTrailing: true))
    }

    @Test func aViewerInLastPlaceHasNoTrailingGap() {
        let ranks = plain(31)
        let slots = LeaderboardWindow.slots(ranks: ranks, viewerIndex: 30)
        #expect(slots.last == .row(30))
        #expect(shownRanks(ranks, viewer: 30) == [1, 2, 3, 29, 30, 31])
    }

    @Test func aGapOfOneRowShowsTheRowInstead() {
        // Viewer at index 6: the window starts at place index 4, so index 3
        // (rank 4) is the only row the fold would hide.
        let ranks = plain(12)
        #expect(shownRanks(ranks, viewer: 6) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        let slots = LeaderboardWindow.slots(ranks: ranks, viewerIndex: 6)
        #expect(!slots.contains { if case .gap(_, _, _, false) = $0 { true } else { false } })
    }

    @Test func aTieCountsAsOnePlaceWhenReachingAroundTheViewer() {
        // Four students tied for 14th is one place; the window still reaches
        // two places above and below it.
        var ranks = plain(13)
        ranks += [14, 14, 14, 14]
        ranks += [18, 19, 20, 21, 22, 23]
        let viewer = 14
        let shown = shownRanks(ranks, viewer: viewer)
        #expect(shown.contains(12))
        #expect(shown.contains(13))
        #expect(shown.filter { $0 == 14 }.count == 4)
        #expect(shown.contains(18))
        #expect(shown.contains(19))
        #expect(!shown.contains(20))
    }

    @Test func aViewerWithNoPlaceSeesTheTopFive() {
        let ranks = plain(20)
        let slots = LeaderboardWindow.slots(ranks: ranks, viewerIndex: nil)
        #expect(shownRanks(ranks, viewer: nil) == [1, 2, 3, 4, 5])
        #expect(slots.last == .gap(count: 15, lowRank: 6, highRank: 20, isTrailing: true))
    }

    @Test func aShortListIsShownWhole() {
        let ranks = plain(4)
        #expect(LeaderboardWindow.slots(ranks: ranks, viewerIndex: 2).count == 4)
        #expect(LeaderboardWindow.slots(ranks: [], viewerIndex: nil).isEmpty)
    }

    @Test func gapLabelsNameTheRunOrTheTail() {
        #expect(
            LeaderboardWindow.gapLabel(count: 8, lowRank: 4, highRank: 11, isTrailing: false)
                == "8 more · 4–11")
        #expect(
            LeaderboardWindow.gapLabel(count: 3, lowRank: 9, highRank: 9, isTrailing: false)
                == "3 more · 9")
        #expect(
            LeaderboardWindow.gapLabel(count: 15, lowRank: 17, highRank: 31, isTrailing: true)
                == "15 more below")
    }
}

@Suite struct LeaderboardStandingTextTests {

    @Test func ordinalsFollowEnglish() {
        let cases: [(Int, String)] = [
            (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"),
            (13, "13th"), (14, "14th"), (21, "21st"), (22, "22nd"), (101, "101st"), (111, "111th"),
        ]
        for (number, text) in cases { #expect(LeaderboardStandingText.ordinal(number) == text) }
    }

    @Test func aTieIsMarkedOnTheRankAndTheHeadline() {
        #expect(LeaderboardStandingText.rankText(rank: 14, isTied: true) == "14=")
        #expect(LeaderboardStandingText.rankText(rank: 14, isTied: false) == "14")
        #expect(LeaderboardStandingText.headline(rank: 14, isTied: true) == "Tied 14th")
        #expect(LeaderboardStandingText.headline(rank: 2, isTied: false) == "2nd")
    }

    @Test func onlyTheTopThreeRanksCarryATier() {
        #expect(LeaderboardStandingText.tier(rank: 1) == "1")
        #expect(LeaderboardStandingText.tier(rank: 3) == "3")
        #expect(LeaderboardStandingText.tier(rank: 4).isEmpty)
    }

    @Test func durationsAreShort() {
        #expect(LeaderboardStandingText.duration(seconds: 20) == "under a minute")
        #expect(LeaderboardStandingText.duration(seconds: 20 * 60) == "20 min")
        #expect(LeaderboardStandingText.duration(seconds: 3 * 3600) == "3 h")
        #expect(LeaderboardStandingText.duration(seconds: 2 * 86_400) == "2 d")
    }
}

@Suite struct LeaderboardNextPlaceTests {

    @Test func theTargetIsTheNearestStrictlyBetterRow() {
        // Best first: 9, 7, 7, 7, 5. The viewer is the last 7.
        let metrics = [9.0, 7, 7, 7, 5]
        #expect(LeaderboardNextPlace.targetIndex(metrics: metrics, viewerIndex: 3) == 0)
        #expect(LeaderboardNextPlace.targetIndex(metrics: metrics, viewerIndex: 4) == 3)
    }

    @Test func nobodyIsAboveTheTopPlaceOrATieForIt() {
        #expect(LeaderboardNextPlace.targetIndex(metrics: [9, 8], viewerIndex: 0) == nil)
        #expect(LeaderboardNextPlace.targetIndex(metrics: [9, 9, 8], viewerIndex: 1) == nil)
        #expect(LeaderboardNextPlace.targetIndex(metrics: [], viewerIndex: 0) == nil)
    }

    @Test func theGapPrintsLikeAMetric() {
        #expect(LeaderboardNextPlace.deltaText(0.004) == "+0.004")
        #expect(LeaderboardNextPlace.deltaText(3) == "+3")
        #expect(LeaderboardNextPlace.deltaText(0.0001).hasPrefix("+0.0001"))
    }
}

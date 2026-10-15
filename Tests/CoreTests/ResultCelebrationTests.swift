// Tests/CoreTests/ResultCelebrationTests.swift
//
// The result page plays a celebration only for a gain, and the state depends
// on the attempts before it (Core/ResultCelebration.swift).

import Testing

@testable import Core

@Suite struct ResultCelebrationTests {

    struct History: Sendable, CustomTestStringConvertible {
        let percent: Int?
        let previous: Int?
        let earlierBest: Int?
        let expected: ResultCelebration?
        let testDescription: String
    }

    @Test(arguments: [
        History(
            percent: 100, previous: nil, earlierBest: nil, expected: .first,
            testDescription: "100% on a first attempt"),
        History(
            percent: 100, previous: 75, earlierBest: 75, expected: .first,
            testDescription: "100% after lower attempts"),
        History(
            percent: 100, previous: 75, earlierBest: 100, expected: .already,
            testDescription: "100% when an earlier attempt also reached 100%"),
        History(
            percent: 100, previous: 100, earlierBest: 100, expected: .already,
            testDescription: "100% again on the next attempt"),
        History(
            percent: 88, previous: 75, earlierBest: 75, expected: .improved,
            testDescription: "higher than the previous attempt"),
        History(
            percent: 88, previous: 75, earlierBest: 100, expected: .improved,
            testDescription: "higher than the previous attempt, below an earlier best"),
        History(
            percent: 75, previous: 75, earlierBest: 75, expected: nil,
            testDescription: "the same as the previous attempt"),
        History(
            percent: 50, previous: 75, earlierBest: 75, expected: nil,
            testDescription: "lower than the previous attempt"),
        History(
            percent: 50, previous: nil, earlierBest: nil, expected: nil,
            testDescription: "below 100% on a first attempt"),
        History(
            percent: nil, previous: 75, earlierBest: 75, expected: nil,
            testDescription: "nothing to grade, as after a failed build"),
    ])
    func theStateFollowsTheHistory(_ history: History) {
        let state = ResultCelebration(
            percent: history.percent, previousPercent: history.previous,
            earlierBestPercent: history.earlierBest)
        #expect(state == history.expected)
    }

    @Test func aRegradeIsReadFromTheResultsAsTheyAreNow() {
        // A regrade replaces an attempt's result. The state reads the stored
        // results, so an earlier 100% that a regrade lowered no longer counts
        // as "already".
        let beforeRegrade = ResultCelebration(percent: 100, previousPercent: 100, earlierBestPercent: 100)
        let afterRegrade = ResultCelebration(percent: 100, previousPercent: 90, earlierBestPercent: 90)
        #expect(beforeRegrade == .already)
        #expect(afterRegrade == .first)
    }
}

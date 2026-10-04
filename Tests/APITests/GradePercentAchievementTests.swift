// Tests/APITests/GradePercentAchievementTests.swift
//
// Every place that turns points into the whole-number percent agrees that 199
// of 200 points is not a perfect score, so no achievement that means "100%"
// is awarded for it (#2018). Before, each one rounded 99.5 up to 100.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct GradePercentAchievementTests {

    private func collection(earned: Double, total: Int) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub", testSetupID: "", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: total, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 1, totalPoints: total, earnedPoints: earned,
            runnerVersion: "test", timestamp: Date())
    }

    @Test func everyPercentPathReads99For199Of200() {
        // The submission page, the ingest's Ace check and the dashboard rows.
        #expect(gradePercent(from: collection(earned: 199, total: 200)) == 99)
        #expect(gradePercent(from: collection(earned: 200, total: 200)) == 100)

        // The stored result's columns, weighted and by test count.
        let weighted = CollectionGradeFields(
            earnedPoints: 199, totalPoints: 200, passCount: nil, totalTests: nil)
        #expect(weighted.gradePercent == 99)
        let byCount = CollectionGradeFields(
            earnedPoints: nil, totalPoints: nil, passCount: 199, totalTests: 200)
        #expect(byCount.gradePercent == 99)

        // The class-goal sweep's numerator.
        let summary = GradeResultSummary(
            resultID: nil, submissionID: "sub", source: nil, receivedAt: nil,
            earnedPoints: 199, totalPoints: 200, passCount: nil, totalTests: nil)
        #expect(summary.gradePercentValue == 99)
    }

    @Test func aPerfectScoreBadgeNeedsAPerfectScore() {
        let perfect = Achievement(
            id: "perfect", name: "Perfect", scope: .individual,
            conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)],
            reward: AchievementReward(type: .badge, label: "Perfect", icon: "💯"))
        let props = TestProperties(achievements: [perfect])

        let almost = gradePercent(from: collection(earned: 199, total: 200)) ?? 0
        #expect(earnedIndividualBadges(props: props, gradePercent: almost, outcomes: []).isEmpty)

        let full = gradePercent(from: collection(earned: 200, total: 200)) ?? 0
        #expect(earnedIndividualBadges(props: props, gradePercent: full, outcomes: []).count == 1)
    }
}

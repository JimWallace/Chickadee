// Tests/CoreTests/AchievementTests.swift

import Foundation
import Testing

@testable import Core

@Suite struct AchievementTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func classGoalAchievementRoundTrips() throws {
        let goal = Achievement(
            id: "ach_classgoal",
            name: "Class Goal: 80% reach mastery",
            detail: "When 80% of the class hits 80%, everyone earns the bonus.",
            scope: .classWide,
            conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)],
            reward: AchievementReward(type: .points, label: "Class Goal Met", points: 5),
            classFraction: 0.8)
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(goal))
        #expect(decoded == goal)
        #expect(decoded.isClassGoal)
        #expect(decoded.reward.points == 5)
        #expect(decoded.gradeThresholdFraction == 0.8)
    }

    @Test func individualBadgeRoundTrips() throws {
        let badge = Achievement(
            id: "ach_ftp",
            name: "First-Try Perfect",
            scope: .individual,
            conditions: [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .attempts, comparator: .atMost, value: 1),
            ],
            reward: AchievementReward(type: .badge, label: "First-Try Perfect", icon: "🌟"))
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(badge))
        #expect(decoded == badge)
        #expect(decoded.reward.icon == "🌟")
        #expect(decoded.isPerSubmissionBadge)
        #expect(decoded.match == .all)
    }

    @Test func classRecordRoundTrips() throws {
        let record = Achievement(
            id: "ach_speed",
            name: "Speed Champion",
            scope: .record,
            reward: AchievementReward(type: .title, label: "Speed Champion"),
            recordDimension: .fastest)
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(record))
        #expect(decoded == record)
        #expect(decoded.isClassRecord)
        #expect(decoded.recordDimension == .fastest)
        #expect(decoded.reward.type == .title)
    }

    @Test func testPropertiesCarriesAchievementsThroughRoundTrip() throws {
        let props = TestProperties(
            testSuites: [],
            achievements: [
                Achievement(
                    id: "g1", name: "Goal", scope: .classWide,
                    conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)],
                    reward: AchievementReward(type: .points, label: "Goal", points: 3),
                    classFraction: 0.8)
            ])
        let decoded = try decoder.decode(TestProperties.self, from: encoder.encode(props))
        #expect(decoded.achievements.count == 1)
        #expect(decoded.achievements.first?.id == "g1")
        #expect(decoded.achievements.first?.classFraction == 0.8)
    }

    @Test func runnerSanitizedStripsAchievements() throws {
        let props = TestProperties(
            achievements: [
                Achievement(
                    id: "g1", name: "Goal", scope: .classWide,
                    conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)],
                    reward: AchievementReward(type: .points, label: "Goal", points: 3))
            ])
        #expect(props.achievements.count == 1)
        // Stripped from the runner-facing manifest so older runners never decode
        // an achievement shape they don't know.
        #expect(props.runnerSanitized().achievements.isEmpty)
    }

    @Test func legacyManifestWithoutAchievementsDecodesToEmpty() throws {
        // A manifest authored before achievements existed has no `achievements` key.
        let json = Data(#"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#.utf8)
        let decoded = try decoder.decode(TestProperties.self, from: json)
        #expect(decoded.achievements.isEmpty)
    }

    // MARK: Back-compat: legacy `kind`-shaped achievements project into conditions.

    @Test func legacyClassGoalDecodesToConditions() throws {
        let json = Data(
            #"""
            {"id":"g1","name":"Mastery","kind":"classGoal","scope":"classWide",
             "reward":{"type":"points","label":"Mastery","points":5},
             "target":{"kind":"assignmentGrade"},"threshold":0.8,"classFraction":0.8}
            """#.utf8)
        let a = try decoder.decode(Achievement.self, from: json)
        #expect(a.scope == .classWide)
        #expect(a.isClassGoal)
        #expect(a.classFraction == 0.8)
        #expect(a.gradeThresholdFraction == 0.8)
        #expect(a.conditions == [AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)])
    }

    @Test func legacyFirstTryPerfectDecodesToConditions() throws {
        let json = Data(
            #"""
            {"id":"ftp","name":"Ace","kind":"firstTryPerfect","scope":"individual",
             "reward":{"type":"badge","label":"Ace"},
             "target":{"kind":"assignmentGrade"},"threshold":1.0,"attemptThreshold":1}
            """#.utf8)
        let a = try decoder.decode(Achievement.self, from: json)
        #expect(a.scope == .individual)
        #expect(a.isPerSubmissionBadge)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .attempts, comparator: .atMost, value: 1),
            ])
    }

    @Test func legacyClassRecordDecodesToRecordScope() throws {
        let json = Data(
            #"""
            {"id":"fast","name":"Fastest","kind":"classRecord","scope":"classWide",
             "reward":{"type":"title","label":"Fastest"},
             "target":{"kind":"assignmentGrade"},"recordDimension":"fastest"}
            """#.utf8)
        let a = try decoder.decode(Achievement.self, from: json)
        #expect(a.scope == .record)
        #expect(a.isClassRecord)
        #expect(a.recordDimension == .fastest)
        #expect(a.conditions.isEmpty)
    }

    // MARK: Condition evaluation.

    @Test func conditionEvaluationHonoursMatch() throws {
        let perfectFirstTry = Achievement(
            id: "x", name: "Ace", scope: .individual,
            conditions: [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .attempts, comparator: .atMost, value: 1),
            ],
            match: .all,
            reward: AchievementReward(type: .badge, label: "Ace"))
        #expect(perfectFirstTry.isSatisfied(by: AchievementSignals(gradePercent: 100, attemptNumber: 1)))
        #expect(!perfectFirstTry.isSatisfied(by: AchievementSignals(gradePercent: 100, attemptNumber: 2)))
        #expect(!perfectFirstTry.isSatisfied(by: AchievementSignals(gradePercent: 99, attemptNumber: 1)))

        let either = Achievement(
            id: "y", name: "Either", scope: .individual,
            conditions: [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .attempts, comparator: .atMost, value: 1),
            ],
            match: .any,
            reward: AchievementReward(type: .badge, label: "Either"))
        #expect(either.isSatisfied(by: AchievementSignals(gradePercent: 50, attemptNumber: 1)))
        #expect(!either.isSatisfied(by: AchievementSignals(gradePercent: 50, attemptNumber: 9)))
    }

    @Test func testPassConditionReadsOutcomes() throws {
        let badge = Achievement(
            id: "tb", name: "Bonus", scope: .individual,
            conditions: [
                AchievementCondition(
                    signal: .testPass, comparator: .atLeast, value: 1,
                    target: AchievementTarget(kind: .testPass, ref: "secrettest_x.py"))
            ],
            reward: AchievementReward(type: .badge, label: "Bonus"))
        let pass = TestOutcome(
            testName: "secrettest_x.py", testClass: nil, tier: .secret, status: .pass,
            shortResult: "ok", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: true)
        #expect(badge.isSatisfied(by: AchievementSignals(gradePercent: 0, outcomes: [pass])))
        #expect(!badge.isSatisfied(by: AchievementSignals(gradePercent: 100, outcomes: [])))
    }
}

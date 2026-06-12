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
            kind: .classGoal,
            scope: .classWide,
            reward: AchievementReward(type: .points, label: "Class Goal Met", points: 5),
            target: AchievementTarget(kind: .suiteItem, ref: "test_accuracy.py"),
            threshold: 0.8,
            classFraction: 0.8)
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(goal))
        #expect(decoded == goal)
        #expect(decoded.kind == .classGoal)
        #expect(decoded.reward.points == 5)
        #expect(decoded.target.ref == "test_accuracy.py")
    }

    @Test func firstTryPerfectBadgeRoundTrips() throws {
        let badge = Achievement(
            id: "ach_ftp",
            name: "First-Try Perfect",
            kind: .firstTryPerfect,
            scope: .individual,
            reward: AchievementReward(type: .badge, label: "First-Try Perfect", icon: "🌟"))
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(badge))
        #expect(decoded == badge)
        #expect(decoded.reward.icon == "🌟")
        #expect(decoded.threshold == nil)
        #expect(decoded.target.kind == .assignmentGrade)  // defaulted
    }

    @Test func classRecordRoundTrips() throws {
        let record = Achievement(
            id: "ach_speed",
            name: "Speed Champion",
            kind: .classRecord,
            scope: .classWide,
            reward: AchievementReward(type: .title, label: "Speed Champion"),
            recordDimension: .fastest)
        let decoded = try decoder.decode(Achievement.self, from: encoder.encode(record))
        #expect(decoded == record)
        #expect(decoded.recordDimension == .fastest)
        #expect(decoded.reward.type == .title)
    }

    @Test func testPropertiesCarriesAchievementsThroughRoundTrip() throws {
        let props = TestProperties(
            testSuites: [],
            achievements: [
                Achievement(
                    id: "g1", name: "Goal", kind: .classGoal, scope: .classWide,
                    reward: AchievementReward(type: .points, label: "Goal", points: 3),
                    threshold: 0.8, classFraction: 0.8)
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
                    id: "g1", name: "Goal", kind: .classGoal, scope: .classWide,
                    reward: AchievementReward(type: .points, label: "Goal", points: 3))
            ])
        #expect(props.achievements.count == 1)
        // Stripped from the runner-facing manifest so older runners never decode
        // an AchievementKind they don't know.
        #expect(props.runnerSanitized().achievements.isEmpty)
    }

    @Test func legacyManifestWithoutAchievementsDecodesToEmpty() throws {
        // A manifest authored before achievements existed has no `achievements` key.
        let json = Data(#"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#.utf8)
        let decoded = try decoder.decode(TestProperties.self, from: json)
        #expect(decoded.achievements.isEmpty)
    }
}

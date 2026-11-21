// Tests/APITests/Gamification/AchievementsEditingRowRefusalTests.swift
//
// The row refusals in `AchievementsEditing` that the editor and MCP suites do
// not reach: an empty name, a site-level row, negative bonus points, an
// unknown record dimension, an unknown signal or comparator, a `testPass` row
// with no test, a negative count or value, a wardrobe reward on a class goal or
// a record in a hand-authored manifest, and a course signal whose target names
// the set it counts over. Each test asserts the parameter the refusal names
// and the words the author reads.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct AchievementsEditingRowRefusalTests {

    /// The parameter name and reason of the `invalidParameter` that `body`
    /// throws, or nil when it throws nothing. Any other error fails the test.
    private func refusal(_ body: () throws -> Void) throws -> (name: String, reason: String)? {
        do {
            try body()
            return nil
        } catch AppError.invalidParameter(let name, let reason) {
            return (name, reason)
        }
    }

    private func row(
        _ conditions: [ConditionRow], scope: String = "individual", points: Int? = nil
    ) -> AchievementRow {
        AchievementRow(
            name: "Goal", scope: scope, conditions: conditions,
            classPercent: scope == "classWide" ? 50 : nil, points: points)
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    // MARK: - Row fields

    @Test(arguments: ["", "   ", "\n"])
    func aBlankNameIsRefused(_ name: String) throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(from: AchievementRow(name: name, scope: "individual"))
        }
        #expect(found?.name == "name")
        #expect(found?.reason == "Name must not be empty.")
    }

    @Test func noEditorSavesASiteAchievement() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(from: AchievementRow(name: "Site", scope: "individual"), at: .site)
        }
        #expect(found?.name == "level")
        #expect(found?.reason == "Site achievements are defined in code, so no editor saves one.")
    }

    @Test func aClassGoalWithNegativePointsIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(from: row([], scope: "classWide", points: -1))
        }
        #expect(found?.name == "points")
        #expect(found?.reason == "Bonus points must be ≥ 0.")
    }

    @Test func aClassGoalWithNoPointsAwardsZero() throws {
        let goal = try AchievementsEditing.achievement(from: row([], scope: "classWide"))
        #expect(goal.reward.points == 0)
        #expect(goal.classFraction == 0.5)
    }

    @Test func anUnknownRecordDimensionIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(
                from: AchievementRow(name: "Quickest", scope: "record", recordDimension: "quickest"))
        }
        #expect(found?.name == "recordDimension")
        #expect(found?.reason == "Unknown record dimension 'quickest'.")
    }

    // MARK: - Condition rows

    @Test func anUnknownSignalIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(from: row([ConditionRow(signal: "luck", comparator: "atLeast")]))
        }
        #expect(found?.name == "signal")
        #expect(found?.reason == "Unknown condition signal 'luck'.")
    }

    @Test func anUnknownComparatorIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(
                from: row([ConditionRow(signal: "attempts", comparator: "near", value: 3)]))
        }
        #expect(found?.name == "comparator")
        #expect(found?.reason == "Unknown comparator 'near'.")
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func aTestPassConditionNeedsATest(_ testRef: String?) throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(
                from: row([ConditionRow(signal: "testPass", comparator: "atLeast", testRef: testRef)]))
        }
        #expect(found?.name == "testRef")
        #expect(found?.reason == "A 'test passes' condition needs a test filename.")
    }

    @Test func aNegativeItemsCoveredCountIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(
                from: row([ConditionRow(signal: "itemsCovered", comparator: "atLeast", value: -1)], scope: "classWide"))
        }
        #expect(found?.name == "value")
        #expect(found?.reason == "Value must not be negative.")
    }

    @Test func aNegativeAttemptsValueIsRefused() throws {
        let found = try refusal {
            _ = try AchievementsEditing.achievement(
                from: row([ConditionRow(signal: "attempts", comparator: "atMost", value: -2)]))
        }
        #expect(found?.name == "value")
        #expect(found?.reason == "Value must not be negative.")
    }

    // MARK: - Hand-authored shapes (validate)

    @Test(arguments: [AchievementScope.classWide, .record])
    func onlyAnIndividualAchievementGrantsAWardrobeItem(_ scope: AchievementScope) throws {
        let achievement = Achievement(
            id: "w", name: "Dressed", scope: scope,
            reward: AchievementReward(type: .wardrobe, label: "Dressed", item: WardrobeItem.grantable.first?.rawValue),
            classFraction: scope == .classWide ? 0.5 : nil,
            recordDimension: scope == .record ? .fastest : nil)
        let found = try refusal {
            try AchievementsEditing.validate([achievement], againstManifest: emptyManifest)
        }
        #expect(found?.name == "rewardType")
        #expect(found?.reason == "'Dressed' grants a wardrobe item, which only an individual achievement can do.")
    }

    /// A course signal's target is the set of assignments it counts over, so
    /// the shape check lets it through; the course check decides whether it
    /// resolves.
    @Test(arguments: [
        (AchievementSignal.assignmentsGraded, TargetKind.courseSection),
        (.assignmentsFullMarks, .concept),
        (.assignmentsEarly, .assignments),
    ])
    func aCourseSignalMayCarryATarget(_ signal: AchievementSignal, _ kind: TargetKind) throws {
        let achievement = Achievement(
            id: "c", name: "Steady", scope: .individual,
            conditions: [
                AchievementCondition(
                    signal: signal, comparator: .atLeast, value: 2, target: AchievementTarget(kind: kind, ref: "x"))
            ],
            reward: AchievementReward(type: .badge, label: "Steady"))
        try AchievementsEditing.validate([achievement], againstManifest: emptyManifest)
    }
}

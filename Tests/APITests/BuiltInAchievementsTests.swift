// Tests/APITests/BuiltInAchievementsTests.swift
//
// Pins the legacy-award fold-in: the built-in awards are now Achievement
// instances (BuiltInAchievements), the display badge is derived from the model
// (AchievementBadge(from:)), and forSubmission / forClassAchievement preserve
// the exact legacy conditions + id→record mapping.

import Core
import Testing

@testable import APIServer

@Suite struct BuiltInAchievementsTests {

    private func badgeIDs(_ ctx: BadgeContext) -> [String] {
        AchievementBadge.forSubmission(ctx).map(\.id)
    }

    @Test func registryCoversEveryLegacyAward() {
        #expect(
            Set(BuiltInAchievements.all.map(\.id)) == [
                "first_try_perfect", "comeback_kid", "tenacious", "speed_demon",
                "pathfinder", "trailblazer", "speed_champion", "minimalist",
            ])
        #expect(BuiltInAchievements.perSubmission.allSatisfy { $0.isPerSubmissionBadge })
        #expect(
            BuiltInAchievements.classRecords.allSatisfy {
                $0.scope == .record && $0.isClassRecord && $0.recordDimension != nil
            })
    }

    @Test func badgeDerivesIdentityFromTheAchievement() {
        let ace = AchievementBadge(from: BuiltInAchievements.ace)
        #expect(ace.id == "first_try_perfect")
        #expect(ace.label == "Ace")  // no icon → bare caption, exactly as before
        #expect(ace.tooltip == "Scored 100% on your very first submission — no warm-up needed.")

        // An icon-bearing reward (the authored-badge style) prefixes the emoji.
        let iconned = AchievementBadge(
            from: Achievement(
                id: "x", name: "Sharpshooter", scope: .individual,
                conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 90)],
                reward: AchievementReward(type: .badge, label: "Sharpshooter", icon: "🌟")))
        #expect(iconned.label == "🌟 Sharpshooter")
    }

    @Test func forSubmissionPreservesLegacyConditionsAndOrder() {
        // First attempt, 100%, slow → Ace only.
        #expect(
            badgeIDs(.init(attemptNumber: 1, gradePercent: 100, executionTimeMs: 5_000, priorGradePercent: nil))
                == ["first_try_perfect"])
        // Big jump → Rally only.
        #expect(
            badgeIDs(.init(attemptNumber: 2, gradePercent: 100, executionTimeMs: 5_000, priorGradePercent: 40))
                == ["comeback_kid"])
        // 100% after many attempts → Tenacious only.
        #expect(
            badgeIDs(.init(attemptNumber: 5, gradePercent: 100, executionTimeMs: 5_000, priorGradePercent: 100))
                == ["tenacious"])
        // Fast 100% → Swift only.
        #expect(
            badgeIDs(.init(attemptNumber: 3, gradePercent: 100, executionTimeMs: 1_000, priorGradePercent: 100))
                == ["speed_demon"])
        // Multiple at once keep registry order (Ace before Swift).
        #expect(
            badgeIDs(.init(attemptNumber: 1, gradePercent: 100, executionTimeMs: 1_000, priorGradePercent: nil))
                == ["first_try_perfect", "speed_demon"])
        // Nothing earned.
        #expect(
            badgeIDs(.init(attemptNumber: 2, gradePercent: 80, executionTimeMs: 5_000, priorGradePercent: 80))
                .isEmpty)
    }

    @Test func forClassAchievementMapsRecordsAndRejectsUnknown() {
        #expect(AchievementBadge.forClassAchievement("trailblazer")?.label == "Trailblazer")
        #expect(AchievementBadge.forClassAchievement("speed_champion")?.label == "Fastest")
        #expect(AchievementBadge.forClassAchievement("minimalist")?.label == "Minimalist")
        #expect(AchievementBadge.forClassAchievement("pathfinder")?.label == "Pathfinder")
        #expect(AchievementBadge.forClassAchievement("not_a_record") == nil)
    }
}

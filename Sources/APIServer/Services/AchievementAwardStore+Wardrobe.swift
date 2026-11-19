// APIServer/Services/AchievementAwardStore+Wardrobe.swift
//
// Grants the wardrobe item an assignment achievement rewards
// (docs/achievement-rewards.md, decision 4, slice S2). The grant runs when the
// student's own result page loads, never while a result is written, so a
// cosmetic can never fail a grade. Like every award, it is sticky: a regrade
// does not take the item back.
//
// Items are account-wide (decision 4.2): a student who already holds the item,
// from any course or rule, earns the award but no new item, and the page shows
// no toast for it.

import Core
import Fluent
import Foundation
import Logging

/// The wardrobe achievements of `props` that one submission satisfies: the
/// individual achievements whose reward names a grantable item. The signals
/// are every one the result page knows, the per-submission ones and the
/// grade and test ones together, so any condition an individual badge may
/// carry may also gate an item.
func earnedWardrobeRewards(
    _ context: BadgeContext, props: TestProperties?, standings: (standing: Int, matchesWon: Int)? = nil
) -> [Achievement] {
    let candidates = (props?.achievements ?? []).filter {
        $0.scope == .individual && $0.reward.wardrobeItem != nil
    }
    guard !candidates.isEmpty else { return [] }
    let signals = AchievementSignals(
        gradePercent: context.gradePercent,
        attemptNumber: context.attemptNumber,
        executionTimeMs: context.executionTimeMs,
        priorGradePercent: context.priorGradePercent,
        outcomes: context.outcomes,
        testNameAliases: context.testNameAliases,
        standing: standings?.standing,
        matchesWon: standings?.matchesWon)
    return candidates.filter { $0.isSatisfied(by: signals) }
}

extension AchievementAwardStore {

    /// An item one page load granted, and the name of the achievement that
    /// granted it, for the result page's Earned toast.
    struct GrantedItem: Sendable, Equatable {
        let item: WardrobeItem
        let label: String
    }

    /// The `wardrobe_unlocks.source` of an item an assignment achievement
    /// granted: `achievement:assignment:<test setup>:<achievement id>`.
    static func wardrobeSource(testSetupID: String, achievementID: String) -> String {
        "achievement:\(AchievementLevel.assignment.rawValue):\(testSetupID):\(achievementID)"
    }

    /// Stores each of `achievements` (satisfied wardrobe achievements of the
    /// test setup `testSetupID`) in `userID`'s ledger, and its item in their
    /// wardrobe when they do not hold it yet. Returns the items this call
    /// stored, in `achievements` order. A row another request stored first is
    /// skipped; every other database error is thrown.
    @discardableResult
    static func grantWardrobeRewards(
        _ achievements: [Achievement], testSetupID: String, submissionID: String, earnedBy userID: UUID,
        on db: any Database
    ) async throws -> [GrantedItem] {
        let wanted = achievements.filter { $0.reward.wardrobeItem != nil }
        guard !wanted.isEmpty else { return [] }
        let level = AchievementLevel.assignment
        let storedAwards = try await APIAchievementAward.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$level == level.rawValue)
            .filter(\.$ownerID == testSetupID)
            .filter(\.$achievementID ~~ wanted.map(\.id))
            .all()
        var awarded = Set(storedAwards.map(\.achievementID))
        var held = try await WardrobeUnlockStore.unlocked(for: userID, on: db)
        var granted: [GrantedItem] = []
        for achievement in wanted {
            guard let item = achievement.reward.wardrobeItem else { continue }
            if awarded.insert(achievement.id).inserted {
                try await APIAchievementAward(
                    userID: userID, level: level, ownerID: testSetupID, achievementID: achievement.id,
                    submissionID: submissionID, label: achievement.name, detail: achievement.detail
                ).createIgnoringConflict(on: db)
            }
            guard held.insert(item).inserted else { continue }
            do {
                try await APIWardrobeUnlock(
                    userID: userID, item: item,
                    source: wardrobeSource(testSetupID: testSetupID, achievementID: achievement.id),
                    label: achievement.name
                ).create(on: db)
                granted.append(GrantedItem(item: item, label: achievement.name))
            } catch  where isInsertConflict(error) {
                continue
            }
        }
        return granted
    }

    /// `grantWardrobeRewards`, for a page that must render whatever happens:
    /// a failure is logged, the page shows no toast, and the next load grants
    /// again.
    static func grantWardrobeRewardsOrLog(
        _ achievements: [Achievement], testSetupID: String, submissionID: String, earnedBy userID: UUID,
        on db: any Database, logger: Logger
    ) async -> [GrantedItem] {
        do {
            return try await grantWardrobeRewards(
                achievements, testSetupID: testSetupID, submissionID: submissionID, earnedBy: userID, on: db)
        } catch {
            logger.warning(
                "achievement wardrobe grant failed",
                metadata: ["test_setup_id": .string(testSetupID), "error": .string("\(error)")])
            return []
        }
    }
}

// APIServer/Services/AchievementAwardStore.swift
//
// Stores the achievements a student earns and reads them back
// (docs/achievement-rewards.md, decision 2, slice S1). The writes happen when
// the student's own result page or dashboard loads, never while a result is
// written, so an award can never fail a grade. A stored award is never taken
// back.
//
// S1 stores the assignment-level individual badges: the per-submission
// built-ins and the instructor-authored individual badges, which is what
// `badgesEarnedBySubmission` returns. Class records keep `class_achievements`
// and class goals keep `achievement_results`.

import Core
import Fluent
import Foundation
import Logging

enum AchievementAwardStore {

    /// The awards `userID` has stored, oldest first.
    static func awards(for userID: UUID, on db: any Database) async throws -> [APIAchievementAward] {
        try await APIAchievementAward.query(on: db)
            .filter(\.$userID == userID)
            .sort(\.$earnedAt, .ascending)
            .all()
    }

    /// The badges one submission earned by itself on one assignment.
    struct Earned {
        let testSetupID: String
        let submissionID: String
        let badges: [AchievementBadge]
    }

    /// Which award a stored row or an earned badge is.
    private struct AwardKey: Hashable {
        let ownerID: String
        let achievementID: String
    }

    /// Stores each earned badge that `userID` has not stored yet, and returns
    /// the rows this call wrote. One query reads what is stored for every
    /// assignment in `earned`, so a dashboard with many assignments costs one
    /// read, and nothing more once every award is stored.
    ///
    /// A badge stored already is left as it is, so its first submission and
    /// its first caption are kept. When two loads write the same badge at
    /// once, the unique index keeps one row and the other insert is ignored.
    /// Every other database error is thrown.
    @discardableResult
    static func record(
        _ earned: [Earned], earnedBy userID: UUID, on db: any Database
    ) async throws -> [APIAchievementAward] {
        let wanted = earned.filter { !$0.badges.isEmpty }
        guard !wanted.isEmpty else { return [] }
        let level = AchievementLevel.assignment
        let stored = try await APIAchievementAward.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$level == level.rawValue)
            .filter(\.$ownerID ~~ Array(Set(wanted.map(\.testSetupID))))
            .all()
        var seen = Set(stored.map { AwardKey(ownerID: $0.ownerID, achievementID: $0.achievementID) })
        var written: [APIAchievementAward] = []
        for group in wanted {
            for badge in group.badges
            where seen.insert(AwardKey(ownerID: group.testSetupID, achievementID: badge.id)).inserted {
                let row = APIAchievementAward(
                    userID: userID, level: level, ownerID: group.testSetupID, achievementID: badge.id,
                    submissionID: group.submissionID, label: badge.label, detail: badge.tooltip)
                do {
                    try await row.create(on: db)
                    written.append(row)
                } catch  where isInsertConflict(error) {
                    continue
                }
            }
        }
        return written
    }

    /// `record`, for a page that must render whatever happens: a failure is
    /// logged and the page goes on. The next load writes again.
    static func recordOrLog(_ earned: [Earned], earnedBy userID: UUID, on db: any Database, logger: Logger) async {
        do {
            try await record(earned, earnedBy: userID, on: db)
        } catch {
            logger.warning(
                "achievement award write failed",
                metadata: [
                    "test_setup_ids": .string(earned.map(\.testSetupID).joined(separator: ",")),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Removes every assignment-level award for the test setups in
    /// `testSetupIDs`. Course and assignment deletion call this, because the
    /// rows name student work that no longer exists.
    static func deleteAwards(forTestSetups testSetupIDs: [String], on db: any Database) async throws {
        guard !testSetupIDs.isEmpty else { return }
        try await APIAchievementAward.query(on: db)
            .filter(\.$level == AchievementLevel.assignment.rawValue)
            .filter(\.$ownerID ~~ testSetupIDs)
            .delete()
    }
}

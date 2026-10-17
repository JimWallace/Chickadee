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

    /// Stores each of `badges` that `userID` has not stored yet for the
    /// assignment of `testSetupID`, and returns the rows this call wrote. A
    /// badge stored already is left as it is, so its first submission and its
    /// first caption are kept. When two loads write the same badge at once,
    /// the unique index keeps one row and the other save fails quietly.
    @discardableResult
    static func record(
        _ badges: [AchievementBadge], earnedBy userID: UUID, testSetupID: String, submissionID: String,
        on db: any Database
    ) async throws -> [APIAchievementAward] {
        guard !badges.isEmpty else { return [] }
        let level = AchievementLevel.assignment
        let stored = try await APIAchievementAward.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$level == level.rawValue)
            .filter(\.$ownerID == testSetupID)
            .all()
        var seen = Set(stored.map(\.achievementID))
        var written: [APIAchievementAward] = []
        for badge in badges where seen.insert(badge.id).inserted {
            let row = APIAchievementAward(
                userID: userID, level: level, ownerID: testSetupID, achievementID: badge.id,
                submissionID: submissionID, label: badge.label, detail: badge.tooltip)
            if (try? await row.save(on: db)) != nil { written.append(row) }
        }
        return written
    }

    /// `record`, for a page that must render whatever happens: a failure is
    /// logged and the page goes on. The next load writes again.
    static func recordOrLog(
        _ badges: [AchievementBadge], earnedBy userID: UUID, testSetupID: String, submissionID: String,
        on db: any Database, logger: Logger
    ) async {
        do {
            try await record(badges, earnedBy: userID, testSetupID: testSetupID, submissionID: submissionID, on: db)
        } catch {
            logger.warning(
                "achievement award write failed",
                metadata: ["test_setup_id": .string(testSetupID), "error": .string("\(error)")])
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

// APIServer/Helpers/ClassGoalBonus.swift
//
// The positive grade bonus a class goal awards.  Class goals are a class-wide
// reward: when (at least the configured share of) the class reaches the
// threshold, every student who submitted earns the same bonus, scaled by how
// far the class got (`APIAchievementResult.progress`).  The bonus is applied as
// **extra credit, capped at 100%** (the user-chosen semantic) at each
// grade-of-record site — the submission page, the BrightSpace push, and the
// grades CSV — so it never reduces anyone's grade and never exceeds full marks.
//
// 0 when the assignment defines no points-rewarded class goals (the common
// case), so this is a no-op for ordinary assignments.

import Core
import Fluent
import Foundation

/// Total class-goal bonus points for an assignment: Σ over its points-rewarded
/// class goals of `reward.points × current class progress`.
func classGoalBonusPoints(testSetupID: String, on db: Database) async throws -> Double {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let props = setup.decodedManifest()
    else { return 0 }
    let goals = props.achievements.filter { $0.isClassGoal }
    guard !goals.isEmpty else { return 0 }

    let rows = try await APIAchievementResult.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .all()
    var progressByID: [String: Double] = [:]
    for row in rows { progressByID[row.achievementID] = row.progress }

    return goals.reduce(0.0) { sum, goal in
        sum + Double(goal.reward.points ?? 0) * (progressByID[goal.id] ?? 0)
    }
}

/// Adds a class-goal bonus to an earned-points grade as extra credit, capped at
/// the suite total so the percentage never exceeds 100%.  A 0 bonus or a
/// non-positive total leaves the grade untouched.
func earnedWithClassGoalBonus(earned: Double, total: Double, bonus: Double) -> Double {
    guard total > 0, bonus > 0 else { return earned }
    return min(total, earned + bonus)
}

/// The suite's total possible points (sum of test-suite item weights) for a
/// loaded setup, or nil when the manifest is missing/malformed or sums to zero.
/// Used as the 100% cap for the class-goal bonus on the points-based exports.
func suiteTotalPoints(setup: APITestSetup) -> Double? {
    guard let props = setup.decodedManifest() else { return nil }
    let total = props.testSuites.map(\.points).reduce(0, +)
    return total > 0 ? Double(total) : nil
}

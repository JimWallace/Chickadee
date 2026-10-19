// APIServer/Helpers/ClassGoalBonus.swift
//
// The positive grade bonus a class goal awards.  Class goals are a class-wide
// reward: when (at least the configured share of) the class reaches the
// threshold, every student who submitted earns the same bonus, scaled by how
// far the class got (`APIAchievementResult.progress`).  The bonus is applied as
// **true extra credit, uncapped** at each grade-of-record site — the submission
// page, the BrightSpace push, and the grades CSV — so it never reduces anyone's
// grade and a student already at full marks is credited above 100%.
//
// It used to be capped at 100%, which made the reward invisible to exactly the
// students who earned it: a goal conditioned on "N% of the class reaches 100%"
// puts most of the class at full marks, where the cap absorbed the whole bonus.
// (HLTH 230 Lab 9: a +1 bonus worth 25% of a 4-point suite showed up as no
// change at all for the majority.)  A class goal is a reward for collective
// work, so it now reads as one.
//
// 0 when the assignment defines no points-rewarded class goals (the common
// case), so this is a no-op for ordinary assignments.
//
// For an activity that runs once per lab group, each lab's goal is counted
// from that lab's own work, and a student earns their own lab's bonus
// (`LabGoalGroups`; docs/lab-groups.md, slice 5).

import Core
import Fluent
import Foundation

/// Total class-goal bonus points that `userID` earns on an assignment: Σ over
/// its points-rewarded class goals of `reward.points × progress`, where the
/// progress is the class's, or for an activity that runs per lab group, the
/// student's lab's.
///
/// Takes the caller's already-decoded manifest (#1128): every call site has
/// the setup row in hand, so this no longer re-fetches and re-decodes it.
func classGoalBonusPoints(
    testSetupID: String, props: TestProperties?, userID: UUID?, on db: any Database
) async throws -> Double {
    guard let props else { return 0 }
    let goals = props.achievements.filter(\.isClassGoal)
    guard !goals.isEmpty else { return 0 }
    let snapshots = try await LabGoalGroups.snapshots(
        testSetupID: testSetupID, props: props, userID: userID, on: db)
    return classGoalBonusPoints(goals: goals, snapshots: snapshots)
}

/// Σ over `goals` of `reward.points × progress`, from snapshots by
/// achievement. A goal with no snapshot yet adds nothing.
func classGoalBonusPoints(goals: [Achievement], snapshots: [String: any ClassGoalSnapshot]) -> Double {
    goals.reduce(0.0) { sum, goal in
        sum + Double(goal.reward.points ?? 0) * (snapshots[goal.id]?.progress ?? 0)
    }
}

/// Adds a class-goal bonus to an earned-points grade as true extra credit: the
/// result may exceed the suite total, so a student already at full marks is
/// credited above 100%.  A 0 bonus leaves the grade untouched.
///
/// `total` no longer bounds the result, but it still gates the operation: the
/// bonus is denominated in suite points, so it means nothing against a suite
/// whose total is unknown or zero, and adding it there would put the grade on a
/// scale nothing else shares.
///
/// The single place the bonus semantic lives — all three grade-of-record sites
/// call this rather than re-deriving it, which is how the grades CSV came to
/// carry its own copy of the old cap.
func earnedWithClassGoalBonus(earned: Double, total: Double, bonus: Double) -> Double {
    guard total > 0, bonus > 0 else { return earned }
    return earned + bonus
}

/// The suite's total possible points (sum of test-suite item weights) from a
/// decoded manifest, or nil when the manifest is missing/malformed or sums to
/// zero.  Used as the 100% cap for the class-goal bonus on the points-based
/// exports and as the BrightSpace push denominator.
func suiteTotalPoints(props: TestProperties?) -> Double? {
    guard let props else { return nil }
    let total = props.testSuites.map(\.points).reduce(0, +)
    return total > 0 ? Double(total) : nil
}

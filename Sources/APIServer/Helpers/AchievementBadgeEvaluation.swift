// APIServer/Helpers/AchievementBadgeEvaluation.swift
//
// Per-student evaluation of the instructor-authorable individual badges — the
// ones decided purely by grade and/or a test passing (`isAuthorableIndividual
// Badge`).  Unlike class goals (a periodic class sweep), an individual badge is
// decided entirely by one student's own result, so it's evaluated at
// submission-display time.  Reads every tier's outcomes so a badge keyed to a
// *secret* test still works — the badge is shown to the student while the test
// itself stays hidden.

import Core
import Fluent
import Foundation

/// The individual badges this submission earned, as display badges.  Returns []
/// when the assignment authors none (the common case).  Takes the caller's
/// already-decoded manifest (#1128) — pure, no re-fetch.
func earnedIndividualBadges(
    props: TestProperties?,
    gradePercent: Int,
    outcomes: [TestOutcome],
    standings: (standing: Int, matchesWon: Int)? = nil
) -> [AchievementBadge] {
    guard let props else { return [] }
    let authored = props.achievements.filter { $0.isAuthorableIndividualBadge }
    guard !authored.isEmpty else { return [] }

    // Grade + test-pass badges read only the grade and the per-test outcomes;
    // the dynamic signals (attempt count, time) belong to the per-submission
    // badges, evaluated separately in `AchievementBadge.forSubmission`.  The
    // alias map lets a `testPass` ref authored as a filename resolve against
    // the display-name-or-stem `testName` runners actually stamp (audit A1).
    // `standings` is the student's current place in a round robin
    // (`standingSignals`), nil on every other assignment, where a
    // `standing` / `matchesWon` condition is unmet.
    let signals = AchievementSignals(
        gradePercent: gradePercent,
        outcomes: outcomes,
        testNameAliases: props.testNameAliases(),
        standing: standings?.standing,
        matchesWon: standings?.matchesWon)
    return authored.compactMap { ach in
        ach.isSatisfied(by: signals) ? AchievementBadge(from: ach) : nil
    }
}

/// The badges one graded submission earns by itself: the per-submission
/// badges and the authored individual badges.  The submission page, the
/// student dashboard and the staff per-student page all call this, so a
/// badge shows on all three pages or on none (#2020).  Class-wide badges are
/// appended by each caller.
///
/// Every badge reads `context.gradePercent`, the raw autograded grade.  A
/// class-goal bonus is extra credit for the class, not a part of this
/// submission's result, so it never earns a badge.
func badgesEarnedBySubmission(
    _ context: BadgeContext,
    props: TestProperties?,
    standings: (standing: Int, matchesWon: Int)? = nil
) -> [AchievementBadge] {
    AchievementBadge.forSubmission(
        context,
        achievements: BuiltInAchievements.manifestPerSubmission(props: props),
        disabled: Set(props?.disabledBuiltInAwardIDs ?? []))
        + earnedIndividualBadges(
            props: props,
            gradePercent: context.gradePercent,
            outcomes: context.outcomes,
            standings: standings)
}

/// The student's current round-robin place for each assignment that needs
/// it: a standings activity that authors an individual badge.  Every other
/// assignment is skipped, so a page with no such assignment makes no query.
func standingsBySetupID(
    propsBySetupID: [String: TestProperties], userID: UUID, on db: Database
) async throws -> [String: (standing: Int, matchesWon: Int)] {
    var standings: [String: (standing: Int, matchesWon: Int)] = [:]
    for (setupID, props) in propsBySetupID
    where props.activity?.kind.aggregation == .standings
        && props.achievements.contains(where: \.isAuthorableIndividualBadge)
    {
        standings[setupID] = try await standingSignals(testSetupID: setupID, userID: userID, on: db)
    }
    return standings
}

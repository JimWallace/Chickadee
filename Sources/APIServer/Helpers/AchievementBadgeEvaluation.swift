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

/// The individual badges to show for a submission's display result — the
/// handler passes the already-decoded collection (fetched once from the
/// result_collections side table, #1173) and this evaluates the authored
/// individual badges.  Returns [] when there is no decodable result.  Lifted
/// out of the submission handler to keep that function within its length budget.
func earnedIndividualBadgesForDisplay(
    collection: TestOutcomeCollection?,
    props: TestProperties?,
    gradePercent: Int,
    standings: (standing: Int, matchesWon: Int)? = nil
) -> [AchievementBadge] {
    guard let collection else { return [] }
    return earnedIndividualBadges(
        props: props,
        gradePercent: gradePercent,
        outcomes: collection.outcomes,
        standings: standings)
}

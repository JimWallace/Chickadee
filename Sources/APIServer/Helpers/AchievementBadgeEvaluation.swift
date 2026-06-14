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
/// when the assignment authors none (the common case).
func earnedIndividualBadges(
    testSetupID: String,
    gradePercent: Int,
    outcomes: [TestOutcome],
    on db: Database
) async throws -> [AchievementBadge] {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let props = setup.decodedManifest()
    else { return [] }
    let authored = props.achievements.filter { $0.isAuthorableIndividualBadge }
    guard !authored.isEmpty else { return [] }

    // Grade + test-pass badges read only the grade and the per-test outcomes;
    // the dynamic signals (attempt count, time) belong to the per-submission
    // badges, evaluated separately in `AchievementBadge.forSubmission`.
    let signals = AchievementSignals(gradePercent: gradePercent, outcomes: outcomes)
    return authored.compactMap { ach in
        ach.isSatisfied(by: signals) ? AchievementBadge(from: ach) : nil
    }
}

/// The individual badges to show for a submission's display result: decodes the
/// stored collection (reusing the handler's date-aware decoder) and evaluates
/// the authored individual badges.  Returns [] when there is no result.  Lifted
/// out of the submission handler to keep that function within its length budget.
func earnedIndividualBadgesForDisplay(
    displayResult: APIResult?,
    submission: APISubmission,
    gradePercent: Int,
    decoder: JSONDecoder,
    on db: Database
) async throws -> [AchievementBadge] {
    guard let result = displayResult,
        let collection = try? decoder.decode(
            TestOutcomeCollection.self, from: Data(result.collectionJSON.utf8))
    else { return [] }
    return try await earnedIndividualBadges(
        testSetupID: submission.testSetupID,
        gradePercent: gradePercent,
        outcomes: collection.outcomes,
        on: db)
}

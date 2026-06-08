// APIServer/Helpers/AchievementBadgeEvaluation.swift
//
// Per-student evaluation of the instructor-authorable individual badges
// (`thresholdBadge` / `testBadge`).  Unlike class goals (a periodic class
// sweep), an individual badge is decided entirely by one student's own result,
// so it's evaluated at submission-display time.  Reads every tier's outcomes so
// a badge keyed to a *secret* test still works — the badge is shown to the
// student while the test itself stays hidden.

import Core
import Fluent
import Foundation

/// True for the instructor-authorable individual-badge kinds: a per-student
/// threshold or test-pass with a cosmetic badge reward.  Excludes the
/// still-hardcoded `firstTryPerfect` (which isn't authored into the manifest).
func isAuthorableIndividualBadge(_ a: Achievement) -> Bool {
    a.scope == .individual && a.reward.type == .badge
        && (a.kind == .thresholdBadge || a.kind == .testBadge)
}

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
    let authored = props.achievements.filter(isAuthorableIndividualBadge)
    guard !authored.isEmpty else { return [] }

    return authored.compactMap { ach in
        guard individualBadgeEarned(ach, gradePercent: gradePercent, outcomes: outcomes) else {
            return nil
        }
        let icon = ach.reward.icon.map { "\($0) " } ?? ""
        return AchievementBadge(
            id: ach.id,
            label: "\(icon)\(ach.reward.label)",
            tooltip: ach.detail ?? ach.reward.label)
    }
}

private func individualBadgeEarned(
    _ a: Achievement, gradePercent: Int, outcomes: [TestOutcome]
) -> Bool {
    switch a.kind {
    case .thresholdBadge:
        return Double(gradePercent) >= (a.threshold ?? 1) * 100
    case .testBadge:
        guard let ref = a.target.ref else { return false }
        return outcomes.contains { $0.testName == ref && $0.status == .pass }
    default:
        return false
    }
}

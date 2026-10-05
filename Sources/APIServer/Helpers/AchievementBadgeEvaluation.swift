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

// MARK: - Badge context and display badge (moved from Routes/Web/WebContextTypes.swift, #2143)

/// Input data used to compute per-submission achievement badges.
struct BadgeContext {
    let attemptNumber: Int
    let gradePercent: Int
    let executionTimeMs: Int
    /// Grade percent of the immediately preceding attempt; nil on the first attempt.
    let priorGradePercent: Int?
    /// Per-test outcomes, when the evaluation site has them (the submission
    /// page does; the blob-free dashboard rows don't).  Lets a badge mixing a
    /// dynamic signal with `testPass` be satisfiable (audit A14) instead of
    /// its testPass leg being vacuously false.
    let outcomes: [TestOutcome]
    /// Manifest-derived alias map for `testPass` ref resolution (audit A1).
    let testNameAliases: [String: Set<String>]

    init(
        attemptNumber: Int,
        gradePercent: Int,
        executionTimeMs: Int,
        priorGradePercent: Int?,
        outcomes: [TestOutcome] = [],
        testNameAliases: [String: Set<String>] = [:]
    ) {
        self.attemptNumber = attemptNumber
        self.gradePercent = gradePercent
        self.executionTimeMs = executionTimeMs
        self.priorGradePercent = priorGradePercent
        self.outcomes = outcomes
        self.testNameAliases = testNameAliases
    }
}

struct AchievementBadge: Encodable {
    let id: String
    let label: String
    let tooltip: String

    /// Derives the display badge from an `Achievement` — the single place a
    /// badge's caption + tooltip come from, whether the award is built-in
    /// (`BuiltInAchievements`) or instructor-authored.  An emoji icon, when the
    /// reward carries one, is prefixed to the caption.
    init(from achievement: Achievement) {
        let icon = achievement.reward.icon.map { "\($0) " } ?? ""
        id = achievement.id
        label = "\(icon)\(achievement.reward.label)"
        tooltip = achievement.detail ?? achievement.reward.label
    }

    /// Direct memberwise init, retained for tests and any non-Achievement caller.
    init(id: String, label: String, tooltip: String) {
        self.id = id
        self.label = label
        self.tooltip = tooltip
    }

    // MARK: Computation

    /// All per-submission built-in badges earned for the given context.  The
    /// award *conditions* live here (keyed by kind); each badge's identity —
    /// caption + tooltip — comes from `BuiltInAchievements`.  Class-wide badges
    /// are appended separately after a DB query (see `forClassAchievement`).
    /// Per-submission badges earned for `ctx`.  Source precedence: the explicit
    /// `achievements` list (the manifest's authored per-submission achievements,
    /// once seeded) → otherwise the built-in registry minus `disabled`.  Keeping
    /// `achievements` optional means existing callers stay on the registry path
    /// unchanged; manifest-sourced callers pass the list.
    static func forSubmission(
        _ ctx: BadgeContext, achievements: [Achievement]? = nil, disabled: Set<String> = []
    ) -> [AchievementBadge] {
        let source = achievements ?? BuiltInAchievements.perSubmission.filter { !disabled.contains($0.id) }
        let signals = AchievementSignals(
            gradePercent: ctx.gradePercent,
            attemptNumber: ctx.attemptNumber,
            executionTimeMs: ctx.executionTimeMs,
            priorGradePercent: ctx.priorGradePercent,
            outcomes: ctx.outcomes,
            testNameAliases: ctx.testNameAliases)
        return
            source
            .filter { $0.isPerSubmissionBadge && $0.isSatisfied(by: signals) }
            .map(AchievementBadge.init(from:))
    }

    /// Maps a class-achievement ID string to its badge.  Manifest-authored
    /// records resolve first — a custom-ID record or a renamed built-in
    /// displays the instructor's own name/detail (audit A6: these used to be
    /// awarded but permanently invisible) — with the registry as the fallback
    /// for un-seeded manifests.  Returns nil for IDs neither source knows.
    static func forClassAchievement(
        _ achievementID: String,
        manifestAchievements: [Achievement] = [],
        disabled: Set<String> = []
    ) -> AchievementBadge? {
        guard !disabled.contains(achievementID) else { return nil }
        if let authored = manifestAchievements.first(where: {
            $0.id == achievementID && $0.isClassRecord
        }) {
            return AchievementBadge(from: authored)
        }
        return BuiltInAchievements.classRecords
            .first { $0.id == achievementID }
            .map(AchievementBadge.init(from:))
    }

    // MARK: Dashboard overflow

    /// The most badges shown inline on a student-dashboard row before the
    /// remainder collapse into a single "+N" overflow pill.  Bounds the row
    /// height so a student with many awards doesn't make the assignments table
    /// grow — the full set is still shown on the submission view, and the
    /// overflow pill names the hidden ones in its tooltip.
    static let dashboardBadgeDisplayLimit = 3

    /// Splits a dashboard badge list into the inline-visible slice and an
    /// overflow summary.  When the list already fits within `limit`,
    /// `extraCount` is 0 and `extraTooltip` is nil.
    static func dashboardSplit(
        _ badges: [AchievementBadge], limit: Int = dashboardBadgeDisplayLimit
    ) -> (visible: [AchievementBadge], extraCount: Int, extraTooltip: String?) {
        guard badges.count > limit else { return (badges, 0, nil) }
        let hidden = badges.suffix(from: limit)
        return (
            Array(badges.prefix(limit)),
            hidden.count,
            hidden.map(\.label).joined(separator: ", ")
        )
    }
}

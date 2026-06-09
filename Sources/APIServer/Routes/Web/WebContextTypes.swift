// APIServer/Routes/Web/WebContextTypes.swift
//
// View-context structs used as Leaf template data for WebRoutes views.
// Extracted from WebRoutes.swift — no behaviour changes.

import Core
import Foundation

// MARK: - Shared base context

struct BaseContext: Encodable {
    let currentUser: CurrentUserContext?
}

// MARK: - Index page context types

struct TestSetupRow: Encodable {
    let id: String
    let title: String?  // from APIAssignment; nil when instructor sees unpublished setups
    let notebookURL: String
    let submitURL: String
    let historyURL: String
    let suiteCount: Int
    let createdAt: String
    let dueAt: String?  // formatted due date, nil if no assignment or no due date
    /// Formatted automatic open date, set only while the start date is still
    /// in the future. Drives the "Opens …" hint in the Due column; nil once
    /// the assignment has opened or when no open date is set.
    let opensAtText: String?
    let status: String  // "unpublished" | "open" | "closed" (per viewer; preview resolves here)
    /// True only for course staff viewing a Preview assignment: it functions as
    /// open for them but carries a subtle "staff-only" marker so they can tell
    /// at a glance it isn't visible to students yet. Always false for students.
    let staffOnly: Bool
    let isOpen: Bool
    /// True when the Edit link should be shown: the assignment is open for
    /// this user, OR it is closed but the student has previously opened it
    /// (so they can keep reviewing past work).  The Upload link stays gated
    /// on `isOpen` alone — you can never submit to a closed assignment.
    let canEdit: Bool
    let gradingMode: String  // "browser" | "worker"
    let hasNotebook: Bool  // false → hide Edit button (no starter notebook available)
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
    /// True when `bestGradeText` is an instructor override rather than the
    /// runner-computed grade.  Drives the "overridden" tag in the template.
    let gradeIsOverridden: Bool
    let badges: [AchievementBadge]
    /// True when this student has an active deadline extension on this
    /// assignment.  Used by the template to show the Submit button and
    /// surface the effective deadline even when the assignment-wide
    /// deadline has passed.
    let hasActiveExtension: Bool
    /// Formatted deadline that actually applies to this user (assignment
    /// `dueAt` or the extension's `extendedDueAt`, whichever is later).
    /// nil when there's no deadline and no extension.
    let effectiveDueAtText: String?
}

struct LatestSubmissionItem: Encodable {
    let submissionID: String
    let submittedAtText: String
}

/// One rendered group of assignment rows on the student dashboard.  A named
/// section renders an `<h2>` heading; the trailing "ungrouped" bucket carries
/// `name == nil` so it renders no heading.  Folding both kinds into one list
/// lets `index.leaf` render every group with a single shared `#extend`'d row
/// partial (LeafKit 1.x raises a false "cyclically referenced" error if the
/// same partial is extended from more than one site in a template, so the
/// single-loop shape is load-bearing, not just tidier).
struct IndexDisplayGroup: Encodable {
    let name: String?  // nil → ungrouped bucket (no heading)
    let setups: [TestSetupRow]
}

struct IndexContext: Encodable {
    let displayGroups: [IndexDisplayGroup]  // sections (named) then the ungrouped bucket
    let hasAny: Bool  // true if any group has visible items
    let currentUser: CurrentUserContext?
}

// MARK: - Submit page

struct SubmitContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let currentUser: CurrentUserContext?
}

// MARK: - Notebook page

struct NotebookContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let notebookURL: String
    let jupyterLiteEditorURL: String
    let downloadURL: String?
    let gradingMode: String  // "browser" | "worker"
    let showSubmit: Bool
    /// True when the assignment is closed (deadline passed without an active
    /// override, or explicitly closed by the instructor).  The Leaf template
    /// surfaces a "view only" notice and `notebook.js` reads this via the
    /// iframe's `data-read-only` attribute to lock cell editing and run
    /// shortcuts inside JupyterLite.
    let isClosed: Bool
    /// Unix-epoch mtime (seconds) of the user's working-copy notebook file
    /// on disk at render time.  Embedded in the iframe as
    /// `data-working-copy-mtime`; `notebook.js` compares it against a
    /// per-setup value in `localStorage` and force-overwrites the
    /// in-browser IndexedDB copy when the server's mtime is newer (e.g.
    /// after an instructor "Reset notebook" action).  0 if the working
    /// copy could not be stat'd.
    let workingCopyMtime: Int
    let currentUser: CurrentUserContext?
}

// MARK: - Submission history page

struct SubmissionHistoryContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let rows: [SubmissionHistoryRow]
    let currentUser: CurrentUserContext?
}

struct SubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
    let submissionFilename: String?
    let canOpenInNotebook: Bool
    let openInNotebookURL: String?
}

// MARK: - Submission result page

struct OutcomeRow: Encodable {
    let testName: String
    let tier: String
    let status: String  // pass | fail | error | timeout
    let shortResult: String
    let longResult: String?  // full output shown in <details>; nil for passing tests
    let markLabel: String  // Pass | Fail | Error | Timeout | —
    let markClass: String  // pass | fail | error | timeout | skipped
    let isSkipped: Bool  // shortResult matches the dependency-skip pattern
    let blockerName: String?  // extracted prerequisite name ("test_build"), no extension
    let deltaImproved: Bool  // was non-pass last attempt, is pass now
    let deltaRegressed: Bool  // was pass last attempt, is non-pass now
    let pointsLabel: String?  // e.g. "2 pts" when assignment is weighted; nil otherwise
    let hint: String?  // instructor "💡 Hint" callout, present only on failing tests
}

/// One section block on the student submission page.  `sectionName == nil`
/// means "render these outcomes with no heading" — used for the legacy /
/// ungrouped bucket so the page looks identical to the pre-sections layout
/// when an assignment has no sections defined.
struct SectionedOutcomes: Encodable {
    let sectionName: String?
    let outcomes: [OutcomeRow]
    /// Aggregate pass/fail counts for the secret-tier tests that belong to
    /// this section (students only; nil when the section has no secret tests
    /// or the viewer is an instructor, who sees secret tests itemized as
    /// ordinary rows instead).  Secret tests are never named or itemized for
    /// students — surfacing the per-section count lets a student see *where*
    /// hidden tests are failing without revealing which.
    let secretSummary: TierSummary?
}

/// Input data used to compute per-submission achievement badges.
struct BadgeContext {
    let attemptNumber: Int
    let gradePercent: Int
    let executionTimeMs: Int
    /// Grade percent of the immediately preceding attempt; nil on the first attempt.
    let priorGradePercent: Int?
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
    static func forSubmission(
        _ ctx: BadgeContext, disabled: Set<String> = []
    ) -> [AchievementBadge] {
        BuiltInAchievements.perSubmission
            .filter { !disabled.contains($0.id) && perSubmissionEarned($0, ctx: ctx) }
            .map(AchievementBadge.init(from:))
    }

    /// Whether a per-submission award's (now parameterized) condition is met for
    /// `ctx`.  Reads the thresholds off the achievement, defaulting to the
    /// legacy constants (attempt 1 / +50 pts / 5 attempts / 2 s @ 100%) so the
    /// built-in defaults behave exactly as before.
    private static func perSubmissionEarned(_ a: Achievement, ctx: BadgeContext) -> Bool {
        // `threshold` is a 0…1 grade fraction; default 100%.  gradePercent never
        // exceeds 100, so `>=` collapses to `==` at the default.
        let gradeCutoff = Int(((a.threshold ?? 1.0) * 100).rounded())
        switch a.kind {
        case .firstTryPerfect:
            return ctx.attemptNumber <= (a.attemptThreshold ?? 1) && ctx.gradePercent >= gradeCutoff
        case .comeback:
            guard let prior = ctx.priorGradePercent else { return false }
            return ctx.gradePercent - prior >= (a.jumpThresholdPercent ?? 50)
        case .persistence:
            return ctx.attemptNumber >= (a.attemptThreshold ?? 5) && ctx.gradePercent >= gradeCutoff
        case .speedRun:
            return ctx.gradePercent >= gradeCutoff && ctx.executionTimeMs < (a.timeThresholdMs ?? 2_000)
        default:
            return false
        }
    }

    /// Maps a class-achievement ID string to its badge, returning nil for unknown IDs.
    static func forClassAchievement(
        _ achievementID: String, disabled: Set<String> = []
    ) -> AchievementBadge? {
        guard !disabled.contains(achievementID) else { return nil }
        return BuiltInAchievements.classRecords
            .first { $0.id == achievementID }
            .map(AchievementBadge.init(from:))
    }
}

/// Aggregate pass/fail summary for a tier that is never itemized for the
/// student (currently secret).  No individual test names or output are
/// included — only counts.
struct TierSummary: Encodable {
    let total: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    /// true = release tier hidden until deadline; false = secret (never shown)
    let isRelease: Bool

    init(outcomes: [TestOutcome], isRelease: Bool) {
        total = outcomes.count
        passCount = outcomes.filter { $0.status == .pass }.count
        failCount = outcomes.filter { $0.status == .fail }.count
        errorCount = outcomes.filter { $0.status == .error }.count
        timeoutCount = outcomes.filter { $0.status == .timeout }.count
        self.isRelease = isRelease
    }
}

struct SubmissionContext: Encodable {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let submissionFilename: String?
    let openInNotebookURL: String?
    let isPending: Bool
    /// True when the browser run is done but the worker hasn't reported yet.
    let isBrowserComplete: Bool
    /// "browser" or "worker" — which result is currently displayed.
    let resultSource: String
    let buildFailed: Bool
    let compilerOutput: String?
    let hasWarnings: Bool
    let warnings: [String]
    let outcomes: [OutcomeRow]
    /// Outcomes grouped into sections for the student view.  When a manifest
    /// has no sections (or no outcome carries a sectionID) this is a single
    /// bucket with `sectionName == nil`, which the template renders with no
    /// header — behaviour identical to the pre-sections page.
    let sectionedOutcomes: [SectionedOutcomes]
    let passCount: Int
    let totalTests: Int
    let gradePercent: Int
    /// True when an instructor has overridden this student's grade for the
    /// assignment.  The override is the effective grade regardless of this
    /// attempt's autograded score; the template shows `overrideGradeText`.
    let gradeIsOverridden: Bool
    /// Formatted override grade (e.g. "85%"), nil when not overridden.
    let overrideGradeText: String?
    let executionTimeMs: Int
    /// True when any test has points > 1 (i.e. grade uses weighted points).
    let isWeighted: Bool
    /// Sum of points across all tiers; equals totalTests when unweighted.
    let totalPoints: Int
    /// Sum of `points × score` across all tiers (partial credit included),
    /// preformatted for display ("3", "2.75"); equals passCount when unweighted.
    let earnedPoints: String
    /// True when a prior attempt exists and delta data is populated.
    let hasDelta: Bool
    /// E.g. "↑ fixed 2 tests · ↓ broke 1 test since attempt 3"; nil on first attempt.
    let deltaHeaderText: String?
    let badges: [AchievementBadge]
    let currentUser: CurrentUserContext?
    /// Class-wide goals for this assignment with their current progress, shown
    /// as an "Achievements" section.  Empty when the assignment has no class
    /// goals (or the sweep hasn't produced a snapshot yet).
    let classGoals: [ClassGoalView]
}

/// One class-goal achievement's display state for the submission page.
struct ClassGoalView: Encodable {
    let name: String
    let detail: String?
    /// e.g. "+5 pts", or the reward label for non-points rewards.
    let rewardLabel: String
    /// 0–100 — the share of the goal reached (the progress-bar fill).
    let progressPercent: Int
    let studentsMeeting: Int
    let denominator: Int
    /// True once the class has fully reached the goal.
    let met: Bool
    /// True once the deadline has passed and the snapshot is final.
    let locked: Bool
}

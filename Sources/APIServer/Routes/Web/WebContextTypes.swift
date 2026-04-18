// APIServer/Routes/Web/WebContextTypes.swift
//
// View-context structs used as Leaf template data for WebRoutes views.
// Extracted from WebRoutes.swift — no behaviour changes.

import Foundation
import Core

// MARK: - Shared base context

struct BaseContext: Encodable {
    let currentUser: CurrentUserContext?
}

// MARK: - Index page context types

struct TestSetupRow: Encodable {
    let id: String
    let title: String?      // from APIAssignment; nil when instructor sees unpublished setups
    let suiteCount: Int
    let createdAt: String
    let dueAt: String?      // formatted due date, nil if no assignment or no due date
    let status: String      // "unpublished" | "open" | "closed"
    let isOpen: Bool
    let gradingMode: String  // "browser" | "worker"
    let hasNotebook: Bool   // false → hide Edit button (no starter notebook available)
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
    let badges: [AchievementBadge]
}

struct LatestSubmissionItem: Encodable {
    let submissionID: String
    let submittedAtText: String
}

struct IndexSectionContext: Encodable {
    let sectionID: String
    let name: String
    let setups: [TestSetupRow]
}

struct IndexContext: Encodable {
    let sections: [IndexSectionContext]     // named sections with their visible items
    let ungroupedSetups: [TestSetupRow]     // items not assigned to any section
    let hasSections: Bool                   // true if the course has any defined sections
    let hasUngrouped: Bool                  // true if there are items not in any section
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
    let gradingMode: String          // "browser" | "worker"
    let showSubmit: Bool
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
    let status: String           // pass | fail | error | timeout
    let shortResult: String
    let longResult: String?      // full output shown in <details>; nil for passing tests
    let markLabel: String        // Pass | Fail | Error | Timeout | —
    let markClass: String        // pass | fail | error | timeout | skipped
    let isSkipped: Bool          // shortResult matches the dependency-skip pattern
    let blockerName: String?     // extracted prerequisite name ("test_build"), no extension
    let deltaImproved: Bool      // was non-pass last attempt, is pass now
    let deltaRegressed: Bool     // was pass last attempt, is non-pass now
    let pointsLabel: String?     // e.g. "2 pts" when assignment is weighted; nil otherwise
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

    // MARK: Per-submission badges

    static let firstTryPerfect = AchievementBadge(
        id: "first_try_perfect",
        label: "Ace",
        tooltip: "Scored 100% on your very first submission — no warm-up needed."
    )
    static let comebackKid = AchievementBadge(
        id: "comeback_kid",
        label: "Rally",
        tooltip: "Jumped 50 or more percentage points in a single submission."
    )
    static let tenacious = AchievementBadge(
        id: "tenacious",
        label: "Tenacious",
        tooltip: "Reached 100% after 5 or more attempts — persistence pays off."
    )
    static let speedDemon = AchievementBadge(
        id: "speed_demon",
        label: "Swift",
        tooltip: "Scored 100% with every test completing in under 2 seconds total."
    )

    // MARK: Class-wide badges

    static let pathfinder = AchievementBadge(
        id: "pathfinder",
        label: "Pathfinder",
        tooltip: "Submitted before anyone else in the class."
    )
    static let trailblazer = AchievementBadge(
        id: "trailblazer",
        label: "Trailblazer",
        tooltip: "First student in the class to reach 100% on this assignment."
    )
    static let speedChampion = AchievementBadge(
        id: "speed_champion",
        label: "Fastest",
        tooltip: "Holds the class record for fastest 100% execution time."
    )
    static let minimalist = AchievementBadge(
        id: "minimalist",
        label: "Minimalist",
        tooltip: "Reached 100% in fewer attempts than any other student in the class."
    )

    // MARK: Computation

    /// Returns all per-submission badges earned for the given context.
    /// Class-wide badges are appended separately after a DB query.
    static func forSubmission(_ ctx: BadgeContext) -> [AchievementBadge] {
        var badges: [AchievementBadge] = []
        if ctx.attemptNumber == 1, ctx.gradePercent == 100 {
            badges.append(.firstTryPerfect)
        }
        if let prior = ctx.priorGradePercent, ctx.gradePercent - prior >= 50 {
            badges.append(.comebackKid)
        }
        if ctx.attemptNumber >= 5, ctx.gradePercent == 100 {
            badges.append(.tenacious)
        }
        if ctx.gradePercent == 100, ctx.executionTimeMs < 2_000 {
            badges.append(.speedDemon)
        }
        return badges
    }

    /// Maps a class-achievement ID string to its badge, returning nil for unknown IDs.
    static func forClassAchievement(_ achievementID: String) -> AchievementBadge? {
        switch achievementID {
        case "pathfinder":     return .pathfinder
        case "trailblazer":    return .trailblazer
        case "speed_champion": return .speedChampion
        case "minimalist":     return .minimalist
        default:               return nil
        }
    }
}

/// Aggregate summary for a hidden test tier (release before deadline, or secret).
/// No individual test names or output are included — only counts.
struct TierSummary: Encodable {
    let total: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    /// true = release tier hidden until deadline; false = secret (never shown)
    let isRelease: Bool

    init(outcomes: [TestOutcome], isRelease: Bool) {
        total        = outcomes.count
        passCount    = outcomes.filter { $0.status == .pass }.count
        failCount    = outcomes.filter { $0.status == .fail }.count
        errorCount   = outcomes.filter { $0.status == .error }.count
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
    let passCount: Int
    let totalTests: Int
    let gradePercent: Int
    let executionTimeMs: Int
    /// True when any test has points > 1 (i.e. grade uses weighted points).
    let isWeighted: Bool
    /// Sum of points for all visible outcomes; equals totalTests when unweighted.
    let totalPoints: Int
    /// Sum of points for passing outcomes; equals passCount when unweighted.
    let earnedPoints: Int
    /// True when a prior attempt exists and delta data is populated.
    let hasDelta: Bool
    /// E.g. "↑ fixed 2 tests · ↓ broke 1 test since attempt 3"; nil on first attempt.
    let deltaHeaderText: String?
    /// Non-nil for students when release tests exist but are not yet visible (before deadline).
    let releaseSummary: TierSummary?
    /// Non-nil for students when secret tests exist (always hidden).
    let secretSummary: TierSummary?
    let badges: [AchievementBadge]
    let currentUser: CurrentUserContext?
}

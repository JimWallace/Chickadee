// APIServer/Routes/Web/WebContextTypes.swift
//
// View-context structs used as Leaf template data for WebRoutes views.
// Extracted from WebRoutes.swift — no behaviour changes.

import Core
import Foundation

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
    /// Inline-visible achievement badges only — capped to
    /// `AchievementBadge.dashboardBadgeDisplayLimit` so a student with many
    /// awards doesn't balloon the row height.  The full set still shows on the
    /// submission view.
    let badges: [AchievementBadge]
    /// Count of earned badges beyond the inline-visible `badges` slice.  0 when
    /// every earned badge fits; otherwise drives the "+N" overflow pill.
    let extraBadgeCount: Int
    /// Comma-joined labels of the overflow badges, surfaced as the "+N" pill's
    /// tooltip.  nil when `extraBadgeCount` is 0.
    let extraBadgesTooltip: String?
    /// True when this student has an active deadline extension on this
    /// assignment.  Used by the template to show the Submit button and
    /// surface the effective deadline even when the assignment-wide
    /// deadline has passed.
    let hasActiveExtension: Bool
    /// Formatted deadline that actually applies to this user (assignment
    /// `dueAt` or the extension's `extendedDueAt`, whichever is later).
    /// nil when there's no deadline and no extension.
    let effectiveDueAtText: String?
    /// True when the slip-day action is offered on this row (#1228): the
    /// deadline passed inside the claim window, the viewer is a student with
    /// balance, and no staff extension stands in the way.
    let slipDayAvailable: Bool
    let slipDayURL: String
    /// Tooltip/aria text for the calendar action, naming the exact deadline
    /// the spend would produce ("Use a slip day — extends your deadline to
    /// …"); empty when the action is hidden.
    let slipDayActionLabel: String
}

struct LatestSubmissionItem: Encodable {
    let submissionID: String
    let submittedAtText: String
}

/// One ungraded content item (reference material) rendered inside a section on
/// the dashboards.  Shared by the student view (published items only) and the
/// instructor view (all items; `isPublished == false` shows a "Hidden" marker).
/// Ungraded, so it carries none of `TestSetupRow`'s grade / history / badge
/// fields — just a title, a kind label, and its links.
/// One hosted file attachment on a content item, ready for the download link
/// (the gated `/content-files/:itemID/:attachmentID` route).
struct ContentAttachmentView: Encodable {
    let id: String
    let displayName: String
    let downloadURL: String
    let sizeLabel: String  // e.g. "1.2 MB"
}

struct ContentItemRow: Encodable {
    let id: String
    let title: String
    let kind: String  // raw ContentItemKind
    let kindLabel: String  // human-facing label, e.g. "Notebook"
    let itemDescription: String?
    let links: [ContentLink]
    /// Hosted file attachments, rendered as download links beside `links`.
    let attachments: [ContentAttachmentView]
    let updatedLabel: String?
    /// False → a draft item hidden from students (surfaced only on the
    /// instructor dashboard as a "Hidden" marker).
    let isPublished: Bool

    init(from item: APICourseContentItem) {
        let itemID = item.id?.uuidString ?? ""
        self.id = itemID
        self.title = item.title
        self.kind = item.kind.rawValue
        self.kindLabel = ContentItemRow.label(for: item.kind)
        self.itemDescription = item.itemDescription
        self.links = item.links
        self.attachments = item.attachments.map { attachment in
            ContentAttachmentView(
                id: attachment.id.uuidString,
                displayName: attachment.displayName,
                downloadURL: "/content-files/\(itemID)/\(attachment.id.uuidString)",
                sizeLabel: ByteCountFormatter.string(
                    fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
        }
        self.updatedLabel = item.updatedLabel
        self.isPublished = item.isPublished
    }

    static func label(for kind: ContentItemKind) -> String {
        switch kind {
        case .link: return "Link"
        case .notebook: return "Notebook"
        case .document: return "Document"
        case .slides: return "Slides"
        case .outline: return "Outline"
        case .heading: return "Heading"
        }
    }
}

/// One element of a section's unified item list on the student dashboard: a
/// graded assignment row (`setup`) OR an ungraded content item (`content`),
/// discriminated by `isContent`. Materials and assignments interleave in one
/// `sort_order` sequence, so a reading can sit between two labs rather than
/// living in a separate lane above them.
struct IndexSectionItem: Encodable {
    let isContent: Bool
    /// Populated when `!isContent`.
    let setup: TestSetupRow?
    /// Populated when `isContent`.
    let content: ContentItemRow?

    static func assignment(_ setup: TestSetupRow) -> IndexSectionItem {
        IndexSectionItem(isContent: false, setup: setup, content: nil)
    }
    static func material(_ content: ContentItemRow) -> IndexSectionItem {
        IndexSectionItem(isContent: true, setup: nil, content: content)
    }
}

/// One rendered group on the student dashboard.  A named section renders an
/// `<h2>` heading; the trailing "ungrouped" bucket carries `name == nil` so it
/// renders no heading.  Each group carries one ordered `items` list that
/// interleaves the section's assignments and content items by their shared
/// `sort_order` (the two stacked lanes were merged in the unified-interleave
/// pass).  The row markup is inlined in `index.leaf` (rather than a shared
/// `#extend`'d partial) because LeafKit 1.x raises a false "cyclically
/// referenced" error if the same partial is extended from more than one site.
struct IndexDisplayGroup: Encodable {
    let name: String?  // nil → ungrouped bucket (no heading)
    let items: [IndexSectionItem]
}

struct IndexContext: Encodable {
    let displayGroups: [IndexDisplayGroup]  // sections (named) then the ungrouped bucket
    let hasAny: Bool  // true if any group has visible items
    let currentUser: CurrentUserContext?
    /// "Slip days: 1 of 2 remaining." under the course heading; nil hides the
    /// line (policy off, staff viewer, or no active course).  Precomputed as
    /// one string so the template stays a plain nil-check (#1228).
    let slipDaySummary: String?
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
    /// True when the request's User-Agent is below Chickadee's supported-browser
    /// matrix (`SupportedBrowserMatrix`) — drives a non-blocking "your browser may
    /// not be fully supported" banner.  Conservative: only a confidently-old
    /// browser sets this; an unknown/unparseable UA does not.
    let browserUnsupported: Bool
    let showSubmit: Bool
    /// True when the assignment is closed (deadline passed without an active
    /// override, or explicitly closed by the instructor).  Drives the
    /// submission affordances and the header notice.
    let isClosed: Bool
    /// True when the editor itself must be locked: `notebook.js` reads this via
    /// the iframe's `data-read-only` attribute to disable cell editing and run
    /// shortcuts inside JupyterLite.  A closed assignment is read-only for
    /// students, but *not* for course staff — they author the starter and
    /// solution notebooks in this editor, and an assignment is closed for the
    /// whole time it is being written (creation, cloning, and every save return
    /// it to `.closed`).  Submission stays gated by `isClosed` for everyone.
    let isReadOnly: Bool
    /// True when the viewer may write what they are editing back to the
    /// assignment — course staff (TA+) on a non-archived course, viewing the
    /// starter or solution notebook (never a past submission).  Renders the
    /// "Save to assignment" button, which POSTs to
    /// `/testsetups/:id/notebook/save`.
    let canSaveToAssignment: Bool
    /// Which notebook is open — `"assignment"` or `"solution"`.  Labels the
    /// save button and rides along as the endpoint's `?file=` argument.
    let fileKind: String
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
    /// True iff `classGoals` is non-empty.  The template gates the "Class goals"
    /// heading on this explicit Swift-computed flag rather than
    /// `!classGoals.isEmpty` in Leaf, so an empty goal list never leaks a bare
    /// heading regardless of how the Leaf encoder represents an empty array.
    let hasClassGoals: Bool
    /// True when this viewer may spend their secret-reveal token here:
    /// toggle on, manifest has secret tests, viewer is the (non-staff)
    /// owner, token not yet spent.  Renders the offer box + POST form.
    let secretRevealAvailable: Bool
    /// True when the reveal is active (toggle on + token spent): secret
    /// rows are itemized and the "revealed" info banner shows.
    let secretRevealActive: Bool
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

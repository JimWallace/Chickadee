// APIServer/Routes/Web/AssignmentListContexts.swift
//
// Leaf view-context types for the instructor dashboard listing and the
// per-assignment submissions drilldown.  Split from the original
// `AssignmentContextTypes.swift` so each `Encodable` synthesis lives in
// its own translation unit and only gets re-checked when the relevant
// view changes.

import Core
import Fluent
import Foundation
import Vapor

struct AssignmentRow: Encodable {
    let setupID: String
    let assignmentID: String?  // nil if unpublished
    let title: String?  // nil if unpublished
    let isOpen: Bool?  // nil if unpublished
    let dueAt: String?
    let status: String  // "unpublished" | "open" | "closed"
    let sortOrder: Int?
    let validationStatus: String
    let validationSubmissionID: String?
    /// Multi-variant validation rollup for the validation cell: "none" (the
    /// assignment does not vary by student, or no batch has run yet) |
    /// "pending" | "failed" | "passed".  A flat discriminator plus
    /// pre-rendered text, because LeafKit 1.14.2 mis-parses compound
    /// conditions and cannot do the arithmetic.
    let variantState: String
    let variantSummaryText: String  // e.g. "1 of 4 variants failed"; "" when none
    /// The lowest-index failed variant's submission id, for the results link.
    let failedVariantSubmissionID: String?
    let suiteCount: Int
    let createdAt: String
    let submittedStudentCount: Int?  // nil if unpublished; unique enrolled students who submitted at least once
    let vanityURL: String?  // e.g. "/CS101/lab-1-intro"; nil if unpublished or no active course
    let leaderboardURL: String?  // the class activity's board; nil when not an activity
}

/// Aggregate of one setup's current validation-variant batch (multi-variant
/// validation): the reference solution graded against N synthetic per-student
/// seeds, on top of the primary run.  Fold-down for the listing row.
struct ValidationVariantSummary {
    let total: Int
    let failed: Int
    let pending: Int
    let firstFailedSubmissionID: String?

    /// The flat discriminator the template branches on.  Pending wins over
    /// failed so a half-graded batch reads as still running rather than as a
    /// settled verdict.
    var state: String {
        if total == 0 { return "none" }
        if pending > 0 { return "pending" }
        return failed > 0 ? "failed" : "passed"
    }

    var summaryText: String {
        switch state {
        case "pending": return "\(total) variants running"
        case "failed": return "\(failed) of \(total) variants failed"
        case "passed": return "\(total) variants passed"
        default: return ""
        }
    }
}

/// A course section with its unified item list (assignments + content items
/// interleaved by `sort_order`), used on the instructor dashboard.
struct CourseSectionRow: Encodable {
    let sectionID: String  // UUID as string
    let name: String
    let defaultGradingMode: String  // "browser" | "worker"
    let sortOrder: Int
    /// Assignments and content items in this section, interleaved and sorted.
    let items: [InstructorSectionItem]
}

/// Overview tab (`GET /instructor`): dashboard metrics + the assignment /
/// section listing.  The enrolled-students roster and BrightSpace export
/// moved to their own tabs (`/instructor/students`, `/instructor/brightspace`)
/// in the v0.4 instructor-view rework, so this context no longer carries the
/// roster — only `enrolledStudentCount`, which the per-assignment "X / Y"
/// submitted badge still needs.
struct AssignmentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let sections: [CourseSectionRow]  // sections with their interleaved items
    /// Assignments + content items not in any section, interleaved and sorted.
    let ungroupedItems: [InstructorSectionItem]
    let hasSections: Bool
    /// Whether to render the trailing "Ungrouped" block — true when there are
    /// ungrouped items, or no sections at all (flat-table mode). Precomputed so
    /// the template branches on a flat bool (LeafKit 1.14.2 mis-parses chained
    /// `||`).
    let showUngroupedBlock: Bool
    /// Whether to render the "No assignments yet" empty message — true only when
    /// the course has nothing to list in any lane. Precomputed for the same
    /// reason.
    let showEmptyMessage: Bool
    let enrolledStudentCount: Int
}

/// Students tab (`GET /instructor/students`): the enrolled-students roster
/// plus enrollment-mode controls.  The table self-updates by polling
/// `GET /instructor/students-data`, which returns `[EnrolledStudentRow]`.
struct InstructorStudentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    /// Student-role rows plus pending pre-enrolments: the polled table.
    let enrolledStudents: [EnrolledStudentRow]
    /// Instructor and TA rows: a small static list above the students.
    let staffRows: [EnrolledStudentRow]
    let hasStaff: Bool
    let hasEnrolledStudents: Bool  // explicit flag — Leaf's array.isEmpty is unreliable
    let enrolledStudentCount: Int
    /// Student-role enrolments only, and the pending count beside it, for the
    /// title bar's "31 enrolled · 2 pending".
    let activeStudentCount: Int
    let pendingCount: Int
    /// Whether the students list has enough rows to earn a Filter box
    /// (`ListFilterPolicy`).
    let showStudentFilter: Bool
    let courseEnrollmentMode: String
    let courseIsArchived: Bool
    /// True when BrightSpace is configured on the server AND the active course
    /// is linked to a LEARN org unit, or the course reads its roster from the
    /// LMS through NRPS — gates the "Check against LEARN" button.
    let brightspaceLinkAvailable: Bool
    /// True when the viewer may manage the roster (change roles, unenroll, invite
    /// staff): a per-course instructor or an admin. TAs pass the `/instructor`
    /// gate but see the roster read-only (#417 Slice F). Independent of archived.
    let canManageRoster: Bool
    /// `courseIsArchived || !canManageRoster` — folded so the Leaf template gates
    /// every mutating control on one flag (LeafKit 1.14.2 mis-parses `||`).
    let rosterReadOnly: Bool
    /// Flash banners after a staff-invite POST redirect.
    let flashSuccess: String?
    let flashError: String?
}

/// One bar of a server-rendered sparkline.  `heightPercent` is already
/// normalized to 0–100 against the series maximum, so the Leaf template needs
/// no arithmetic and the chart renders without JavaScript.  Populated buckets
/// are floored to a clearly visible height so a lone student/submission isn't a
/// 2px sliver indistinguishable from an empty bin; `isEmpty` marks a zero-count
/// bucket, which renders as a faint baseline tick (`.spark-fill-empty`) so "no
/// one here" reads differently from "a few here" while the chart still shows
/// its full axis.  `title` is the hover tooltip.
struct SparklineBar: Encodable {
    let heightPercent: Int
    let isEmpty: Bool
    let title: String
}

/// One time-window of the cyclable submissions-over-time card.  `key` is the
/// window-chip text (`24h` / `7d` / `30d`), `headline` the submission count in
/// that window, and `bars` the per-bucket sparkline.  `initiallyHidden` is true
/// for every window after the first, so the page renders the 24h view
/// server-side (works without JS) and the click handler reveals the others.
struct SubmissionsTrendWindow: Encodable {
    let key: String
    let headline: String
    let initiallyHidden: Bool
    let bars: [SparklineBar]
}

/// A statistic card on the assignment-submissions page.  Carries a
/// `{label, value}` headline plus an optional server-rendered distribution
/// sparkline (`bars`, gated by `hasSpark`) — the grade distribution or the
/// attempts-per-student distribution.  The Submissions card instead sets
/// `cyclable` and carries three `windows` (24h/7d/30d) the browser cycles on
/// click, like the dashboard cards.  `sparkSummary` is the screen-reader
/// caption; a card with neither a spark nor windows renders as a plain number.
struct AssignmentStatCard: Encodable {
    let label: String
    let value: String
    let hasSpark: Bool
    let sparkSummary: String
    let bars: [SparklineBar]
    let cyclable: Bool
    let windowChip: String
    let windows: [SubmissionsTrendWindow]
}

struct EnrolledStudentRow: Content {
    let id: String
    let username: String
    let displayName: String
    let role: String  // "student" | "instructor" | "admin" | "(pending)"
    let lastSeenAtText: String
    let lastSeenAtISO: String?
    let submissionsURL: String
    /// URL to POST to to remove this student from the course.  Differs
    /// for active enrollments vs pending pre-enrollments — the template
    /// just uses this verbatim instead of branching on `isPending`.
    let unenrollURL: String
    /// True when this row represents a `pre_enrollments` row (instructor
    /// bulk-enrolled the username via CSV but the student hasn't logged
    /// in yet).  Template renders these visually muted; pending students
    /// have no submissions or last-seen data.
    let isPending: Bool
    /// For pending rows: URL to POST to to manually materialize this
    /// pre-enrollment into a real user (the grade-sync-testing escape valve).
    /// Empty for active enrollments.
    let registerURL: String
    /// URL to POST to to give this student a new class handle.  Empty for a
    /// pending row, which has no enrollment and so no handle.
    var newHandleURL: String = ""
    /// The student's own seeded avatar (the same bird their account page shows),
    /// drawn at the roster size.  Nil for a pending row, which has no account.
    /// Filled by the Students-tab loaders only; the Overview's count-only
    /// roster never draws one.
    var avatar: AvatarPresentation?
    /// Explicit flag for the template: a bare optional in a Leaf conditional is
    /// unreliable, so the partial gates on this instead of on `avatar`.
    var hasAvatar: Bool = false
    /// The badge when LEARN cannot receive this student's grade ("Not on
    /// LEARN"), read from the readiness sweep's stored status.  Nil when the
    /// course is not linked, the student is confirmed, or the sweep has not
    /// classified them.  `LearnUnreachableReason` gives all three values.
    var learnFlag: String?
    /// Why LEARN cannot receive the grade, for the row's details line.
    var learnFlagReason: String?
    /// What staff can do about it, for the row's details line.  Only a student
    /// that LEARN does not list is a candidate for removal.
    var learnFlagAdvice: String?
    /// For a pending row: "Awaiting first login · added from CSV Sep 3".
    var pendingNote: String = ""
}

struct AssignmentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let metrics: [AssignmentStatCard]
    let rows: [AssignmentStudentRow]
    /// One-shot error banner from a redirect back to this page (`?error=`),
    /// rendered by the `_flash` partial in `base.leaf`.
    let flashError: String?
    /// One-shot success banner (`?notice=`), the same partial.
    let flashSuccess: String?
    /// The assignment's secret-reveal toggle.  Gates the whole reveal-token
    /// affordance on this page (spent tag + re-grant action) — when off the
    /// page renders identically to the pre-feature layout.
    let secretRevealEnabled: Bool
    /// The assignment's advisory passing threshold, or nil when off.  Gates
    /// the passing badge column and the Passing metric card.
    let passingThresholdPercent: Int?
    /// One row per suite item on a CONTRIBUTION assignment: whether the class
    /// has collectively covered it, and who got there first.  Empty for every
    /// other assignment, which is what gates the section off the page — the
    /// accumulator only writes rows for assignments declaring contribution
    /// slots, so "has rows" IS "is a contribution assignment".
    let coverageRows: [AssignmentCoverageRow]
    /// True iff `coverageRows` is non-empty.  The template gates on this rather
    /// than on `!coverageRows.isEmpty`, which Leaf cannot express — the same
    /// shape `hasClassGoals` uses on the submission page.
    let hasCoverage: Bool
    /// "9 / 15 items found", for the section's summary chip.
    let coverageSummary: String
    /// The Tournament section's facts (docs/class-activities.md); its
    /// `isTournamentKind` gates the section off every other page.
    let tournament: TournamentControlFacts
}

/// The submissions page's Tournament section: the run control and where
/// the latest run stands. The bracket itself is on the leaderboard page,
/// which staff always reach with names.
struct TournamentControlFacts: Encodable {
    /// True when the activity's aggregation is a bracket.
    let isTournamentKind: Bool
    /// "No tournament has been run yet.", "Round 2 of 3 in progress", …
    let statusText: String
    /// True while the latest run is still playing: the form then asks
    /// before superseding it.
    let hasRunInProgress: Bool
    /// The schedule select: every `TournamentSchedule`, the bracket selected.
    let scheduleOptions: [TournamentScheduleOption]
    let leaderboardURL: String

    static let none = TournamentControlFacts(
        isTournamentKind: false, statusText: "", hasRunInProgress: false, scheduleOptions: [], leaderboardURL: "")

    static func make(setup: APITestSetup, on db: any Database) async throws -> TournamentControlFacts {
        guard let setupID = setup.id, setup.decodedManifest()?.activity?.kind.aggregation == .bracket else {
            return .none
        }
        let latest = try await latestTournament(testSetupID: setupID, on: db)
        return TournamentControlFacts(
            isTournamentKind: true,
            statusText: latest.map { tournamentStatusText(run: $0.run) } ?? "No tournament has been run yet.",
            hasRunInProgress: latest?.run.status == APITournamentRun.Status.running,
            scheduleOptions: TournamentScheduleOption.options(),
            leaderboardURL: "/testsetups/\(setupID)/leaderboard")
    }
}

struct TournamentScheduleOption: Encodable {
    let value: String
    let label: String
    let selected: Bool

    static func options(selected: TournamentSchedule = .bracket) -> [TournamentScheduleOption] {
        TournamentSchedule.allCases.map {
            TournamentScheduleOption(value: $0.rawValue, label: $0.displayName, selected: $0 == selected)
        }
    }
}

/// One sentence on where a run stands, shared by the control and the page.
func tournamentStatusText(run: APITournamentRun) -> String {
    let schedule = run.tournamentSchedule?.displayName ?? run.schedule
    switch run.status {
    case APITournamentRun.Status.complete:
        return "\(schedule): complete after \(run.roundCount) round\(run.roundCount == 1 ? "" : "s")."
    case APITournamentRun.Status.superseded:
        return "\(schedule): superseded by a later run."
    default:
        return "\(schedule): round \(run.currentRound) of \(run.roundCount) in progress."
    }
}

/// One item of a contribution assignment's class-wide coverage.
struct AssignmentCoverageRow: Encodable {
    /// The suite item's runner-stamped name, as it appears in results.
    let item: String
    /// True when someone in the class has covered it.
    let found: Bool
    /// The first finder's username, or "" when nobody has covered it yet.
    let foundBy: String
    /// When it was first covered, preformatted, or "" when uncovered.  Serves
    /// as the no-JS fallback inside the relative-time cell.
    let foundAt: String
    /// The same instant as an ISO-8601 stamp for `js-relative-time`.  "When a
    /// bug was first found" is human-activity recency, which the Timestamps
    /// rule renders relative — as both other "When" columns on the site do.
    let foundAtISO: String
}

struct AssignmentStudentRow: Encodable {
    let studentID: String
    /// Student's UUID (as string), used in URLs that target the student by
    /// their stable identifier — e.g. the per-student "reset notebook"
    /// action.  Distinct from `studentID` which is the username for display.
    let studentUUID: String
    let surname: String
    let givenNames: String
    /// `latest.bestGradeText`, or an em-dash when there is no grade.
    let gradeText: String
    /// Prefill for the inline override form: the active override percent when
    /// one is set, else the runner-computed best grade, else 0.
    let gradeOverridePercent: Int
    /// The submission count, the latest submission and the grade that
    /// counts. `latest.gradeIsOverridden` is true when `gradeText` is an
    /// instructor override rather than the runner-computed best grade.
    let latest: LatestSubmissionCell
    let latestSubmittedAtEpoch: Int  // Unix timestamp (0 if no submission) for chronological sort
    let fullHistoryURL: String
    let bestGradePercent: Int?
    /// True when this student has spent their secret-reveal token on the
    /// assignment (always false when the assignment's toggle is off — the
    /// affordance is hidden entirely then).
    let secretRevealSpent: Bool
    /// The advisory passing badge beside the grade: `"passing"` or `"below
    /// threshold"` when the assignment sets a threshold and the student has a
    /// grade, else nil (no badge). Never a grade change — a label only.
    let passingLabel: String?
    /// True iff `passingLabel == "passing"`; the template picks the badge
    /// colour from this rather than comparing strings in Leaf.
    let isPassing: Bool
}

/// The advisory pass/fail label for one student's effective best grade.
/// Returns nil when the assignment sets no threshold or the student has no
/// grade yet, so no badge renders in either case.
func passingLabel(bestGradePercent: Int?, threshold: Int?) -> String? {
    guard let threshold, let grade = bestGradePercent else { return nil }
    return grade >= threshold ? "passing" : "below threshold"
}

/// MCP tab (`GET /instructor/mcp`): the active course's authoring voice for
/// connected agents, editable by the course's instructors.
struct InstructorMCPContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    /// The course's effective voice guide — its own text when customized, else
    /// Chickadee's default — as the textarea's value. The default is seeded
    /// into the box so the instructor edits a real starting point rather than
    /// composing an addendum against an invisible baseline.
    let guidanceText: String
    /// Character count of `guidanceText`, shown against `maxLength`.
    let guidanceLength: Int
    /// True when `guidanceText` is course-authored rather than the default.
    let isCustomized: Bool
    /// `canEdit && isCustomized` — folded so the template gates the Reset
    /// button on one flag (LeafKit 1.14.2 mis-parses `&&`).
    let showResetButton: Bool
    /// A noun phrase that names where the current text comes from.  It is
    /// chrome in a definition list, so it is not a sentence.
    let sourceNote: String
    let maxLength: Int
    /// True when the viewer may save: a per-course instructor or an admin, and
    /// the course is not archived. TAs pass the `/instructor` gate but see the
    /// panel read-only, matching the Students tab (#417 Slice F).
    let canEdit: Bool
    /// Why the panel is read-only (nil when `canEdit`) — precomputed so the
    /// template renders one flat string instead of branching (LeafKit 1.14.2
    /// mis-parses compound conditions).
    let readOnlyNote: String?
    /// True when the MCP server is not mounted on this deployment (`MCP_MODE`
    /// off/unresolvable) — the panel still saves, with a note that guidance
    /// takes effect once MCP is enabled.
    let mcpDisabled: Bool
    /// Flash banners after the save POST redirect.
    let flashSuccess: String?
    let flashError: String?
}

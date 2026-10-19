// APIServer/Routes/Web/AssignmentListContexts.swift
//
// View-context types for the instructor dashboard listing and the
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
    /// "pending" | "failed" | "passed".
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

/// One bar of a server-rendered sparkline.  `heightPercent` is already
/// normalized to 0–100 against the series maximum, so the view (`DiagnosticCards`)
/// needs no arithmetic and the chart renders without JavaScript.  Populated buckets
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
    /// The role select for an enrolled row; nil for a pending row.
    var roleSelect: RoleSelectCell?
    /// The student's own seeded avatar (the same bird their account page shows),
    /// drawn at the roster size.  Nil for a pending row, which has no account.
    /// Filled by the Students-tab loaders only; the Overview's count-only
    /// roster never draws one.
    var avatar: AvatarPresentation?
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
    /// The student's group in the course's group set (docs/lab-groups.md).
    /// Nil for staff, a pending row, or a student in no group.
    var groupName: String?
    /// The group select for a student row when the set is edited in
    /// Chickadee; nil otherwise. The view shows it only to an instructor.
    var groupSelect: GroupSelectCell?
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
    let scheduleOptions: [SelectOption]
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

/// The tournament form's schedule select.
enum TournamentScheduleOption {
    /// Every schedule, with `selected` marked.
    static func options(selected: TournamentSchedule = .bracket) -> [SelectOption] {
        TournamentSchedule.allCases.map {
            SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == selected)
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
    /// True iff `passingLabel == "passing"`; the page picks the badge
    /// colour from this rather than comparing strings.
    let isPassing: Bool
}

/// The advisory pass/fail label for one student's effective best grade.
/// Returns nil when the assignment sets no threshold or the student has no
/// grade yet, so no badge renders in either case.
func passingLabel(bestGradePercent: Int?, threshold: Int?) -> String? {
    guard let threshold, let grade = bestGradePercent else { return nil }
    return grade >= threshold ? "passing" : "below threshold"
}

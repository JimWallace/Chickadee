// APIServer/Routes/Web/AssignmentListContexts.swift
//
// Leaf view-context types for the instructor dashboard listing and the
// per-assignment submissions drilldown.  Split from the original
// `AssignmentContextTypes.swift` so each `Encodable` synthesis lives in
// its own translation unit and only gets re-checked when the relevant
// view changes.

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
    let suiteCount: Int
    let createdAt: String
    let submittedStudentCount: Int?  // nil if unpublished; unique enrolled students who submitted at least once
    let vanityURL: String?  // e.g. "/CS101/lab-1-intro"; nil if unpublished or no active course
}

/// One element of a section's unified item list on the instructor dashboard: a
/// graded assignment row (`assignment`) OR an ungraded content item (`content`),
/// discriminated by `isContent`. The two lanes interleave in one drag-orderable
/// `sort_order` sequence, so a reading can sit between two labs.
struct InstructorSectionItem: Encodable {
    let isContent: Bool
    /// Populated when `!isContent`.
    let assignment: AssignmentRow?
    /// Populated when `isContent`.
    let content: ContentItemRow?

    static func assignment(_ row: AssignmentRow) -> InstructorSectionItem {
        InstructorSectionItem(isContent: false, assignment: row, content: nil)
    }
    static func material(_ content: ContentItemRow) -> InstructorSectionItem {
        InstructorSectionItem(isContent: true, assignment: nil, content: content)
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
    let enrolledStudents: [EnrolledStudentRow]
    let hasEnrolledStudents: Bool  // explicit flag — Leaf's array.isEmpty is unreliable
    let enrolledStudentCount: Int
    let courseEnrollmentMode: String
    let courseIsArchived: Bool
    /// True when BrightSpace is configured on the server AND the active course
    /// is linked to a LEARN org unit — gates the "Check against LEARN" button.
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

/// BrightSpace tab (`GET /instructor/brightspace`): the per-instructor
/// Connection panel, the assignment→grade-item mapping, roster readiness, and
/// grade export.
struct InstructorBrightspaceContext: Encodable {
    /// The requesting instructor's own LEARN connection (course-independent).
    struct AccountPanel: Encodable {
        let connected: Bool
        /// The connected LEARN identity (whoami display), when connected.
        let identity: String?
        /// Pre-rendered " (since …)" suffix (empty when nil) so the template
        /// interpolates it directly — avoids an inline `#if` in the middle of
        /// a sentence, which LeafKit 1.14.2 mis-parses.
        let since: String?
    }

    /// The identity the active course pushes grades as (its designated
    /// instructor, or the deployment-wide fallback), plus its health.
    struct SyncIdentityPanel: Encodable {
        /// Display name; nil = no identity connected anywhere.
        let name: String?
        /// Precomputed `name != nil` so the template branches on a flat bool.
        let hasName: Bool
        /// True when the designated sync identity is the requesting user.
        let isMe: Bool
        /// False when the course names a designated instructor who no longer
        /// has a stored key (disconnected) — grades defer until reconnect.
        let connected: Bool
        /// True when there's a designated identity but it's disconnected (the
        /// "needs reconnect" / grades-paused state). Pre-computed so the
        /// template can branch with flat sibling conditionals (LeafKit 1.14.2
        /// mis-parses `#if` nested inside an `#if/#else`).
        let needsReconnect: Bool

        static let empty = SyncIdentityPanel(
            name: nil, hasName: false, isMe: false, connected: false, needsReconnect: false)
    }

    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseIsArchived: Bool
    /// True when the server has BrightSpace app credentials configured at all.
    let brightspaceSyncEnabled: Bool
    /// True when this course is bound to a D2L org unit.
    let courseLinked: Bool
    /// "Name (id)" when the org-unit name is known, else the raw id — for the
    /// "Linked to …" line. Nil when unlinked.
    let orgUnitDisplay: String?
    /// The raw org-unit id (or "") prefilled into the Link-course form.
    let orgUnitFieldValue: String
    let account: AccountPanel
    let syncIdentity: SyncIdentityPanel
    /// Gates for the Connection panel's forms, precomputed flat (LeafKit
    /// 1.14.2 mis-parses `&&` / nested `#if`): connect form when configured
    /// but not yet connected; identity actions (test / take-over / disconnect
    /// / link) when connected with a non-archived active course; take-over
    /// only when someone else is (or nobody is) the designated identity.
    let showConnectForm: Bool
    let showIdentityActions: Bool
    let showUseMyIdentity: Bool
    let flashSuccess: String?
    let flashError: String?
    /// True when BrightSpace is configured and the active course isn't archived —
    /// gates the top-bar "Sync now" button. Precomputed so the template branches
    /// on a flat bool (LeafKit 1.14.2 mis-parses `&&` / nested `#if`).
    let canSyncNow: Bool
    /// The reserved value the grade-item dropdown submits for the "Do not sync"
    /// option (`BrightspaceSync.doNotSyncToken`), surfaced so the page JS uses
    /// the one server-side source of truth instead of a duplicated literal.
    let doNotSyncToken: String
    let assignmentRows: [BrightspaceAssignmentRow]
    let hasAssignments: Bool
    /// True when the course is linked to a LEARN org unit and not archived —
    /// gates the "Reconcile now" button. Precomputed so the template branches on
    /// a flat bool (LeafKit 1.14.2 mis-parses `&&` / nested `#if`).
    let canReconcile: Bool
    /// Students we can't currently deliver a grade to (not on the LEARN
    /// classlist, or no key to match) — the authoritative replacement for the
    /// old log-heuristic "unmapped students" list.
    let unreachableStudents: [BrightspaceReadinessRow]
    let hasUnreachable: Bool
}

/// Constants shared between the BrightSpace grade-sync server code and the
/// instructor LEARN tab's page JS.
enum BrightspaceSync {
    /// Reserved value the grade-item dropdown submits when the instructor picks
    /// the "Do not sync" option. The save handler maps it to
    /// `brightspaceSyncExcluded` and never stores it; the page JS uses it (via
    /// `doNotSyncToken` in the context) to recognise the option. Not a valid D2L
    /// grade-object ID, so it can't collide with a real mapping.
    static let doNotSyncToken = "__do_not_sync__"
}

/// One assignment's BrightSpace grade-item mapping + its latest sync state.
struct BrightspaceAssignmentRow: Encodable {
    let assignmentID: String  // publicID
    let title: String
    /// The value to prefill the grade-item combobox with: a D2L grade-object ID,
    /// the `BrightspaceSync.doNotSyncToken` (when the assignment is excluded), or
    /// "" when unmapped. The page JS resolves an ID to its display name on load.
    let gradeFieldValue: String
    let lastSyncText: String  // formatted time, or "—"
    let lastSyncStatus: String  // "success" | "error" | "skipped" | "none"
    let lastSyncDetail: String?
    /// Per-assignment student grade-sync rollup across the assignment's result
    /// and override-only rows: how many are synced, still pending a push, or
    /// errored.  Lets the instructor see "Lab 1: 28 synced / 2 pending / 1
    /// errored" at a glance instead of only the single latest log line.
    let syncedCount: Int
    let pendingCount: Int
    let erroredCount: Int
    /// Precomputed visibility flags — Leaf can't reliably coerce an Int to a
    /// bool for `#if`, so the rollup chips gate on these instead of `> 0`.
    let hasSyncActivity: Bool
    let hasPending: Bool
    let hasErrored: Bool
}

/// Headline counts shown as cards atop the panel.
struct BrightspaceSyncSummary: Encodable {
    let synced: Int
    let pending: Int
    let errored: Int
}

/// LEARN roster-readiness rollup for the active course, from the persisted
/// per-enrollment status the reconcile sweep maintains.
struct BrightspaceReadinessSummary: Encodable {
    let confirmed: Int
    let unconfirmed: Int
    let unreachable: Int
    let lastCheckedText: String  // formatted time, or "Never"
    let hasBeenChecked: Bool
}

/// One student Chickadee can't currently deliver a grade to in LEARN, with the
/// reason (not on the classlist, or no key to match).
struct BrightspaceReadinessRow: Encodable {
    let username: String
    let displayName: String
    let detail: String
    let userID: String
    let unenrollURL: String
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
}

struct AssignmentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let metrics: [AssignmentStatCard]
    let rows: [AssignmentStudentRow]
    /// The assignment's secret-reveal toggle.  Gates the whole reveal-token
    /// affordance on this page (spent tag + re-grant action) — when off the
    /// page renders identically to the pre-feature layout.
    let secretRevealEnabled: Bool
}

struct AssignmentStudentRow: Encodable {
    let studentID: String
    /// Student's UUID (as string), used in URLs that target the student by
    /// their stable identifier — e.g. the per-student "reset notebook"
    /// action.  Distinct from `studentID` which is the username for display.
    let studentUUID: String
    let surname: String
    let givenNames: String
    let gradeText: String
    /// True when `gradeText` is an instructor override rather than the
    /// runner-computed best grade.
    let gradeIsOverridden: Bool
    /// Prefill for the inline override form: the active override percent when
    /// one is set, else the runner-computed best grade, else 0.
    let gradeOverridePercent: Int
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let latestSubmittedAtEpoch: Int  // Unix timestamp (0 if no submission) for chronological sort
    let additionalSubmissionCount: Int
    let fullHistoryURL: String
    let bestGradePercent: Int?
    /// True when this student has spent their secret-reveal token on the
    /// assignment (always false when the assignment's toggle is off — the
    /// affordance is hidden entirely then).
    let secretRevealSpent: Bool
}

/// MCP tab (`GET /instructor/mcp`): the active course's authoring guidance for
/// connected agents, editable by the course's instructors.
struct InstructorMCPContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    /// The stored per-course guidance ("" when unset) — the textarea's value.
    let guidanceText: String
    /// The fixed house authoring-voice guide, rendered read-only for reference.
    let houseVoiceGuide: String
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

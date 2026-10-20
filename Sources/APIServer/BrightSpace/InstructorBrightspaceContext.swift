// APIServer/BrightSpace/InstructorBrightspaceContext.swift
//
// The view-model types for the instructor BrightSpace tab
// (`GET /instructor/brightspace`, `InstructorBrightspacePage`).
// `BrightSpacePagePresenter` is their only builder, so they live beside it
// rather than with the route contexts (#1728).

import Core
import Foundation
import Vapor

/// BrightSpace tab (`GET /instructor/brightspace`): the per-instructor
/// Connection panel, the assignment→grade-item mapping, roster readiness, and
/// grade export.
struct InstructorBrightspaceContext: Encodable {
    /// The requesting instructor's own LEARN connection (course-independent).
    struct AccountPanel: Encodable {
        let connected: Bool
        /// The connected LEARN identity (whoami display), when connected.
        let identity: String?
        /// The " (since …)" suffix after the identity, when the date is known.
        let since: String?
    }

    /// The identity the active course pushes grades as (its designated
    /// instructor, or the deployment-wide fallback), plus its health.
    struct SyncIdentityPanel: Encodable {
        /// Display name; nil = no identity connected anywhere.
        let name: String?
        /// True when the designated sync identity is the requesting user.
        let isMe: Bool
        /// False when the course names a designated instructor who no longer
        /// has a stored key (disconnected) — grades defer until reconnect.
        let connected: Bool
        /// True when there's a designated identity but it's disconnected (the
        /// "needs reconnect" / grades-paused state).
        let needsReconnect: Bool

        static let empty = SyncIdentityPanel(
            name: nil, isMe: false, connected: false, needsReconnect: false)
    }

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
    /// Gates for the Connection panel's forms: connect form when configured
    /// but not yet connected; identity actions (test / take-over / disconnect
    /// / link) when connected with a non-archived active course; take-over
    /// only when someone else is (or nobody is) the designated identity.
    let showConnectForm: Bool
    let showIdentityActions: Bool
    let showUseMyIdentity: Bool
    let flashSuccess: String?
    let flashError: String?
    /// True when BrightSpace is configured, the active course isn't archived and
    /// the viewer is its instructor — gates the top-bar "Sync now" button.
    let canSyncNow: Bool
    /// The reserved value the grade-item dropdown submits for the "Do not sync"
    /// option (`BrightspaceSync.doNotSyncToken`), surfaced so the page JS uses
    /// the one server-side source of truth instead of a duplicated literal.
    let doNotSyncToken: String
    let assignmentRows: [BrightspaceAssignmentRow]
    /// True when the course is linked to a LEARN org unit, not archived, and the
    /// viewer is its instructor — gates the "Reconcile now" button.
    let canReconcile: Bool
    /// Students we can't currently deliver a grade to (not on the LEARN
    /// classlist, or no key to match) — the authoritative replacement for the
    /// old log-heuristic "unmapped students" list.
    let unreachableStudents: [BrightspaceReadinessRow]
    /// True when the course is linked to an LTI platform, so the page links
    /// to the LMS grades page. False on every deployment with no platform.
    var showLTIGradesLink = false
    /// True when the course sends its grades through AGS, so Valence is off
    /// for it and the page says so.
    var usesLTIGrades = false
    /// True when the deployment has a service account configured
    /// (`Application.brightSpaceUsesServiceAccount`). Grades then always push
    /// through it, so the per-instructor identity controls and the grades CSV
    /// link are hidden. They are hidden, not removed: with no service account
    /// they are the only way a course can sync at all.
    var usesServiceAccount = false
    /// "Connected" or "Paused" in the title bar: whether the identity this
    /// course pushes as can reach LEARN.
    var syncHealthy = true
    /// Who the course pushes as ("Service account", or a designated
    /// instructor's LEARN name) and a one-line note under it.
    var pushesAsText = ""
    var pushesAsNote = ""
    /// The newest sync attempt for the course, for the facts card.
    var lastSyncISO: String?
    var lastSyncText = "Never"
    /// Whether the facts card offers Change org unit: not archived, and the
    /// service account, or the viewer's own connected account, can verify it.
    var canBindOrgUnit = false
    /// "3 students can't receive grades · checked Sep 3, 2:10 PM".
    var readinessSummary = ""
    /// Whether the viewer may change the course's LEARN setup: an instructor
    /// of a course that is not archived (#2710). Gates Auto-map by name and
    /// each row's grade-item Save and Re-push all grades.
    var canManageCourse = false
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
    /// True when any row of the assignment has synced, is pending or errored.
    var hasSyncActivity: Bool { syncedCount + pendingCount + erroredCount > 0 }
    /// A real grade item is chosen (not empty, not "do not sync"): the state
    /// dot is teal.
    var isMapped = false
    /// The details line: "Last synced Sep 3, 2:10 PM", the failure text when the
    /// latest attempt errored, or "Not synced yet".
    var syncDetailText = ""
    var hasSyncError = false
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
    /// The student's own seeded avatar at the roster size.
    var avatar: AvatarPresentation?
}

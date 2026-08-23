// APIServer/Routes/Web/AdminContextTypes.swift
//
// Leaf template context types for the admin dashboard and its sub-pages.
// Separated from AdminRoutes.swift to keep route handlers readable.

import Core
import Vapor

struct AdminUserRow: Content {
    let id: String
    let displayName: String?
    let username: String
    let role: String
    let createdAt: String
    let lastSeenAt: String?
}

struct AdminWorkerRow: Content {
    let workerID: String
    let hostname: String
    let runnerVersion: String
    let maxConcurrentJobs: Int
    let lastActive: String
    let assignedJobs: Int
    let jobsProcessed: Int
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
    /// Human-readable form of `avgExecutionMs` (e.g. "14s", "850ms"), or nil.
    let avgExecutionFormatted: String?
    /// Human-readable form of `avgQueueWaitMs` (e.g. "3s", "200ms"), or nil.
    let avgQueueWaitFormatted: String?
    /// True when the runner has not checked in within
    /// `RunnerStaleness.offlineAfter`. Computed on the server so the first
    /// render and every background refresh agree — the client-side copy this
    /// replaced only ran during a poll, so a freshly loaded dashboard showed
    /// no offline badges at all until the first tick.
    let isOffline: Bool
}

struct AdminCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let isArchived: Bool
    let enrollmentMode: String
    let enrollmentCount: Int
    let assignmentCount: Int
    let submissionCount: Int
    let createdAt: String
    var brightspaceOrgUnitID: String?
    var brightspaceOrgUnitName: String?
    var brightspaceSyncEnabled: Bool
}

struct AdminRunnerSummary: Encodable {
    let activeJobs: Int
    let maxJobs: Int
    let jobsProcessed: Int
    let avgExecutionFormatted: String?
    let avgQueueWaitFormatted: String?
    let avgOverheadFormatted: String?
    let avgCacheAcquireFormatted: String?
    let avgDownloadFormatted: String?
    let avgPrepFormatted: String?
    /// "<pct>% (<hits>/<total>)" over recent jobs with a recorded cache flag.
    /// `nil` when no recent job reported a `testSetupCacheHit` (e.g. runner is
    /// pre-v0.4.169 or only ran validation submissions).  When non-nil, this
    /// is the only direct signal that the LRU cache is actually paying off
    /// — compare hit-rate against `avgCacheAcquireFormatted` to confirm.
    let cacheHitRateFormatted: String?
    let passedCount: Int
    let failedCount: Int
    let errorCount: Int
    let timeoutCount: Int
}

struct AdminRunnerJobRow: Encodable {
    let submissionID: String
    let assignmentID: String?
    let username: String?
    let finalStatus: String
    let queueWaitMs: Int?
    let executionMs: Int?
    let queueWaitFormatted: String?
    let executionFormatted: String?
    let totalProcessingMs: Int?
    let totalProcessingFormatted: String?
    /// Bytes-on-disk for the per-job workspace, sampled just before
    /// cleanup. Sortable; the formatted variant carries the rendered
    /// "12.4 MB" / "850 KB" string.
    let workdirPeakBytes: Int?
    let workdirPeakFormatted: String?
    let completedAt: String?
}

struct AdminRunnerSnapshotRow: Encodable {
    let recordedAt: String
    let activeJobs: Int
    let maxJobs: Int
    let activeJobsLabel: String
    let utilizationPercent: Int
    let lastPollAt: String?
}

struct AdminStorageRow: Encodable, Sendable {
    let label: String
    let formatted: String
}

/// Per-assignment on-disk footprint: its test-suite (test setup) bytes plus
/// the bytes of every submission graded against that setup.  Sorted largest-
/// first so an admin can see where space is going.
struct AdminAssignmentStorageRow: Encodable, Sendable {
    let assignmentTitle: String
    let courseCode: String
    let testSuiteFormatted: String
    let submissionsFormatted: String
    let submissionCount: Int
    let totalFormatted: String
    /// Raw bytes behind the formatted columns — drive the server-side sort and
    /// the client-side column sorting (so "1.4 GB" sorts above "320 MB").
    let testSuiteBytes: Int
    let submissionsBytes: Int
    let totalBytes: Int
}

struct AdminStorageContext: Encodable, Sendable {
    let rows: [AdminStorageRow]
    let totalFormatted: String
    let dbBackend: String
    let assignments: [AdminAssignmentStorageRow]
}

struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let workers: [AdminWorkerRow]
    let workerSecret: String
    let courses: [AdminCourseRow]
    let version: String
    /// Default (24h) activity series, JSON-encoded into the page so the chart
    /// renders before the first poll.  The client re-fetches GET /admin/activity
    /// when the window changes or on its refresh interval.
    let activityChart: ActivityChartData

    // Explicit initializer (rather than relying on the synthesized memberwise
    // one): under the CI build's batch/non-WMO mode the synthesized init's
    // symbol can fail to emit, producing an "undefined reference to
    // AdminContext.init(...)" link error in chickadee-server. A hand-written
    // init is emitted normally and sidesteps that. It is intentionally
    // identical to the memberwise init, so silence the "unneeded" rule.
    // swiftlint:disable:next unneeded_synthesized_initializer
    init(
        currentUser: CurrentUserContext?,
        activeAdminTab: String,
        workers: [AdminWorkerRow],
        workerSecret: String,
        courses: [AdminCourseRow],
        version: String,
        activityChart: ActivityChartData
    ) {
        self.currentUser = currentUser
        self.activeAdminTab = activeAdminTab
        self.workers = workers
        self.workerSecret = workerSecret
        self.courses = courses
        self.version = version
        self.activityChart = activityChart
    }
}

struct AdminUsersContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let users: [AdminUserRow]
}

/// Context for the rows-only fragment of the runners table (`?fragment=rows`).
struct WorkerRowsFragmentContext: Encodable {
    let workers: [AdminWorkerRow]
}

/// Context for the rows-only fragment of the users table (`?fragment=rows`).
/// Carries exactly what `_user-rows.leaf` reads, so the fragment cannot start
/// depending on page-level state the poll does not compute.
struct UserRowsFragmentContext: Encodable {
    let users: [AdminUserRow]
}

struct AdminMCPCourseRef: Encodable {
    let id: String
    let code: String
    let name: String
}

struct AdminMCPAccountRow: Encodable {
    let id: String
    let username: String
    let createdAt: String
    /// Courses this account is enrolled in — the only courses its tokens may
    /// touch (admins excepted). Empty means the account can do nothing.
    let enrolledCourses: [AdminMCPCourseRef]
}

struct AdminMCPContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    /// True only when MCP is mounted, the signing authority is loaded, and the
    /// issuer/resource resolve — i.e. tokens can actually be minted.
    let enabled: Bool
    /// False in read_only mode: the page hides the read+write mint option and
    /// shows a read-only banner.
    let writeAllowed: Bool
    let issuer: String?
    let resource: String?
    let tokenTTLSeconds: Int
    /// True only in local-auth mode: manual `mcp` service accounts are the
    /// mechanism there. With SSO active, instructors authorize agents via the
    /// browser flow instead, so the service-account UI is hidden.
    let showServiceAccounts: Bool
    let accounts: [AdminMCPAccountRow]
    /// All courses, for the per-account enrollment picker.
    let allCourses: [AdminMCPCourseRef]
    /// Browser-flow OAuth grants (all of them — admin view), with revoke.
    let grants: [AgentGrantRow]
    /// Set immediately after a mint so the page can show the token exactly once.
    let mintedToken: String?
    let mintedFor: String?
    let mintedScopes: String?
    /// A short error key surfaced as a banner (e.g. "username_taken").
    let error: String?
}

struct AdminStoragePageContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let storage: AdminStorageContext
}

struct AdminUserDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let targetUserID: String
    let displayName: String?
    let username: String
    let role: String
    let enrolledCourses: [AdminUserCourseRow]
    let availableCourses: [AdminUserCourseRow]
}

struct AdminUserCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
}

struct AdminCourseDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let course: AdminCourseRow
    let enrolledUsers: [AdminCourseEnrolledUserRow]
    let assignments: [AdminCourseAssignmentRow]
    let isNew: Bool
    let error: String?
}

struct AdminRunnerDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let runner: AdminWorkerRow
    let tags: [String]
    let summary: AdminRunnerSummary
    let recentJobs: [AdminRunnerJobRow]
    let snapshots: [AdminRunnerSnapshotRow]
    let firstSeenAt: String?
}

struct AdminCourseEnrolledUserRow: Encodable {
    let id: String
    let username: String
    let displayName: String?
    let role: String
}

struct AdminCourseAssignmentRow: Encodable {
    let id: String  // publicID — used in /instructor/:id/... URLs
    let title: String
    let dueAt: String?
    let isOpen: Bool
    let visibility: String  // "closed" | "preview" | "open"
}

struct AdminAlertsRuleRow: Encodable {
    let rule: String
    let humanReadable: String
    let isFiring: Bool
    let lastFiredAt: String?
}

struct AdminAlertsContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let enabled: Bool
    let webhookURL: String
    let webhookURLFromEnvironment: Bool
    let checkIntervalSeconds: Int
    let cooldownSeconds: Int
    let runnerOfflineSeconds: Int
    let queueDepthThreshold: Int
    let oldestPendingSeconds: Int
    let errorRatePercent: Int
    let rules: [AdminAlertsRuleRow]
    let recentFirings: [AlertFiringRecord]
    let flashSuccess: String?
    let flashError: String?
}

struct AdminAuditRow: Encodable {
    let timestamp: String
    let actor: String
    /// Coarse grouping (e.g. "Authentication", "MCP / agents").
    let category: String
    /// Human-readable action label (e.g. "MCP access authorized").
    let label: String
    /// Raw machine action identifier, shown as a secondary <code> line.
    let action: String
    let targetType: String?
    let targetID: String?
    let metadata: String
    let remoteAddr: String
}

/// One selectable option in the action-filter dropdown.
struct AdminAuditFilterOption: Encodable {
    let value: String
    let label: String
    let selected: Bool
}

struct AdminAuditContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let rows: [AdminAuditRow]
    /// Available action filters (grouped label shown to the admin).
    let actionOptions: [AdminAuditFilterOption]
    /// The actor substring currently filtered on (echoed back into the input).
    let filterActor: String
    /// True when any filter is active — drives the "Clear filters" affordance.
    let filtered: Bool
    /// Total entries matching the current filter (may exceed the 200 shown).
    let matchCount: Int
}

/// One archived course on the retention report.
struct AdminRetentionRow: Encodable {
    let id: String
    let code: String
    let name: String
    /// Formatted archival timestamp, or "—" if unknown (legacy rows).
    let archivedAt: String
    /// ISO archival timestamp for client-side date sorting ("" if unknown).
    let archivedAtISO: String
    /// Formatted `archivedAt + retentionDays`, or "—" if archival is unknown.
    let purgeEligibleAt: String
    /// ISO purge-eligible timestamp for client-side date sorting ("" if unknown).
    let purgeEligibleAtISO: String
    let submissionCount: Int
    /// True once the retention window has elapsed — the Delete button is only
    /// rendered (and the server only honours a delete) when this is true.
    /// Restore (unarchive) is offered regardless of this flag.
    let isDeletable: Bool
}

struct AdminRetentionContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let retentionDays: Int
    let rows: [AdminRetentionRow]
    /// How many of `rows` are currently past the retention window and eligible
    /// for permanent deletion (drives the summary line).
    let deletableCount: Int
    let flashSuccess: String?
    let flashError: String?
}

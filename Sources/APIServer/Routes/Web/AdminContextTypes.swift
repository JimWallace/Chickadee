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
}

struct AdminCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let isArchived: Bool
    let enrollmentMode: String
    let enrollmentCount: Int
    let assignmentCount: Int
    let createdAt: String
    var brightspaceOrgUnitID: String?
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

struct AdminStorageRow: Encodable {
    let label: String
    let formatted: String
}

/// Per-assignment on-disk footprint: its test-suite (test setup) bytes plus
/// the bytes of every submission graded against that setup.  Sorted largest-
/// first so an admin can see where space is going.
struct AdminAssignmentStorageRow: Encodable {
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

struct AdminStorageContext: Encodable {
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
    let localRunnerAutoStartEnabled: Bool
    let courses: [AdminCourseRow]
    let version: String
}

struct AdminUsersContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let users: [AdminUserRow]
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
    var assignmentCount: Int { assignments.count }
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
    let action: String
    let targetType: String?
    let targetID: String?
    let metadata: String
    let remoteAddr: String
}

struct AdminAuditContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let rows: [AdminAuditRow]
}

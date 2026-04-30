// APIServer/Routes/Web/AdminContextTypes.swift
//
// Leaf template context types for the admin dashboard and its sub-pages.
// Separated from AdminRoutes.swift to keep route handlers readable.

import Vapor
import Core

struct AdminUserRow: Encodable {
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
    let overheadMs: Int?
    let queueWaitFormatted: String?
    let executionFormatted: String?
    let overheadFormatted: String?
    let totalProcessingMs: Int?
    let totalProcessingFormatted: String?
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

struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let users: [AdminUserRow]
    let workers: [AdminWorkerRow]
    let workerSecret: String
    let localRunnerAutoStartEnabled: Bool
    let courses: [AdminCourseRow]
    let version: String
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
    let id: String      // publicID — used in /instructor/:id/... URLs
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

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
    let lastLoginAt: String?
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
}

struct AdminRunnerSummary: Encodable {
    let activeJobs: Int
    let maxJobs: Int
    let jobsProcessed: Int
    let avgExecutionFormatted: String?
    let avgQueueWaitFormatted: String?
    let passedCount: Int
    let failedCount: Int
    let errorCount: Int
    let timeoutCount: Int
}

struct AdminRunnerJobRow: Encodable {
    let submissionID: String
    let assignmentID: String?
    let finalStatus: String
    let queueWaitFormatted: String?
    let executionFormatted: String?
    let totalProcessingFormatted: String?
    let completedAt: String?
    let testsPassed: Int
    let testsFailed: Int
    let testsErrored: Int
    let testsTimedOut: Int
    let skippedCount: Int
}

struct AdminRunnerSnapshotRow: Encodable {
    let recordedAt: String
    let activeJobs: Int
    let maxJobs: Int
    let availableCapacity: Int
    let lastPollAt: String?
    let lastHeartbeatAt: String?
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
    let summary: AdminRunnerSummary
    let recentJobs: [AdminRunnerJobRow]
    let snapshots: [AdminRunnerSnapshotRow]
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

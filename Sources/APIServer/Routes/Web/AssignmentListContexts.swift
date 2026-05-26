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

/// A course section with its grouped assignment rows, used in instructor and student views.
struct CourseSectionRow: Encodable {
    let sectionID: String  // UUID as string
    let name: String
    let defaultGradingMode: String  // "browser" | "worker"
    let sortOrder: Int
    let rows: [AssignmentRow]  // assignments in this section, sorted
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
    let metrics: [InstructorDashboardMetric]
    let sections: [CourseSectionRow]  // sections with their assignments
    let ungroupedRows: [AssignmentRow]  // assignments/setups not in any section
    let hasSections: Bool
    let hasUngrouped: Bool
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
}

/// BrightSpace tab (`GET /instructor/brightspace`): connection status, the
/// assignment→grade-item mapping, the sync log, and grade export.
struct InstructorBrightspaceContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseIsArchived: Bool
    /// True when the server has BrightSpace credentials configured at all.
    let brightspaceSyncEnabled: Bool
    /// True when this course is bound to a D2L org unit (admin-set).
    let courseLinked: Bool
    let orgUnitID: String?
    let orgUnitName: String?
    let assignmentRows: [BrightspaceAssignmentRow]
    let hasAssignments: Bool
    let logRows: [BrightspaceLogRow]
    let hasLog: Bool
    let summary: BrightspaceSyncSummary
    let unmappedStudents: [BrightspaceUnmappedStudentRow]
    let hasUnmapped: Bool
}

/// One assignment's BrightSpace grade-item mapping + its latest sync state.
struct BrightspaceAssignmentRow: Encodable {
    let assignmentID: String  // publicID
    let title: String
    let gradeObjectID: String  // "" when unmapped
    let lastSyncText: String  // formatted time, or "—"
    let lastSyncStatus: String  // "success" | "error" | "skipped" | "none"
    let lastSyncDetail: String?
}

/// One row of the sync-activity log.
struct BrightspaceLogRow: Encodable {
    let attemptedAt: String
    let username: String
    let assignmentTitle: String
    let points: String  // formatted, or "—"
    let status: String  // "success" | "error" | "skipped"
    let detail: String?
}

/// Headline counts shown as cards atop the panel.
struct BrightspaceSyncSummary: Encodable {
    let synced: Int
    let pending: Int
    let errored: Int
    let unmapped: Int
}

/// A student whose grade can't sync because they have no resolvable D2L account.
struct BrightspaceUnmappedStudentRow: Encodable {
    let username: String
    let displayName: String
    let reason: String
}

struct InstructorDashboardMetric: Encodable {
    let label: String
    let value: String
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
}

struct AssignmentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let metrics: [InstructorDashboardMetric]
    let rows: [AssignmentStudentRow]
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
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let latestSubmittedAtEpoch: Int  // Unix timestamp (0 if no submission) for chronological sort
    let additionalSubmissionCount: Int
    let fullHistoryURL: String
    let bestGradePercent: Int?
}

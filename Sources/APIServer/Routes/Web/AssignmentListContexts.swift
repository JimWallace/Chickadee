// APIServer/Routes/Web/AssignmentListContexts.swift
//
// Leaf view-context types for the instructor dashboard listing and the
// per-assignment submissions drilldown.  Split from the original
// `AssignmentContextTypes.swift` so each `Encodable` synthesis lives in
// its own translation unit and only gets re-checked when the relevant
// view changes.

import Foundation

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

struct AssignmentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let metrics: [InstructorDashboardMetric]
    let sections: [CourseSectionRow]  // sections with their assignments
    let ungroupedRows: [AssignmentRow]  // assignments/setups not in any section
    let hasSections: Bool
    let hasUngrouped: Bool
    let enrolledStudents: [EnrolledStudentRow]
    let hasEnrolledStudents: Bool  // explicit flag — Leaf's array.isEmpty is unreliable
    let enrolledStudentCount: Int
    let courseEnrollmentMode: String
    let courseIsArchived: Bool
}

struct InstructorDashboardMetric: Encodable {
    let label: String
    let value: String
}

struct EnrolledStudentRow: Encodable {
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

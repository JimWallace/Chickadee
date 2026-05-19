// APIServer/Routes/Web/StudentSubmissionContexts.swift
//
// Leaf view-context types for the per-student submission views (both the
// instructor-facing per-assignment-per-student history and the
// course-scoped grouped view).  Split from the original
// `AssignmentContextTypes.swift`.

import Foundation

struct AssignmentStudentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let studentID: String
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}

struct AssignmentSubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
}

/// View context for the per-student, grouped-by-assignment view at
/// `/:courseCode/students/:urlToken/submissions`.  Each `StudentAssignmentRow`
/// mirrors `TestSetupRow` from the student dashboard so the same per-row
/// chrome (status / due / grade / latest submission / badges) renders the
/// same way, with an extra Actions column carrying instructor-only
/// affordances (Retest, inline extension form).
struct CourseStudentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let studentName: String
    let studentUsername: String
    let courseCode: String
    let courseName: String
    let backURL: String
    let sections: [StudentAssignmentSectionContext]
    let ungroupedRows: [StudentAssignmentRow]
    let hasSections: Bool
    let hasUngrouped: Bool
}

struct StudentAssignmentSectionContext: Encodable {
    let sectionID: String
    let name: String
    let rows: [StudentAssignmentRow]
}

struct StudentAssignmentRow: Encodable {
    let assignmentID: String
    let title: String
    let status: String  // "open" | "closed"
    let isOpen: Bool
    let dueAtText: String?
    let effectiveDueAtText: String?  // shown when an extension is active
    let hasExtension: Bool
    let extensionFormInput: String  // datetime-local prefill (extension or dueAt)
    let extensionSavePath: String
    let extensionDeletePath: String
    let retestPath: String
    let historyURL: String
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
    let badges: [AchievementBadge]
}

/// Per-student, per-assignment full submission history page.
struct StudentAssignmentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    let studentName: String
    let studentUsername: String
    let courseCode: String
    let assignmentID: String
    let assignmentTitle: String
    let backURL: String
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}

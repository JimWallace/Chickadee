// APIServer/Routes/Web/StudentSubmissionContexts.swift
//
// View types for the per-student submission views: the history row that
// `StudentAssignmentHistoryPage` and `SubmissionHistoryPage` show, and the
// sections and rows of the course-scoped grouped view
// (`CourseStudentSubmissionsPage`).  Split from the original
// `AssignmentContextTypes.swift`.

import Foundation

struct AssignmentSubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
}

/// One course section of the per-student, grouped-by-assignment view at
/// `/:courseCode/students/:urlToken/submissions` (`CourseStudentSubmissionsPage`).
/// Each `StudentAssignmentRow` mirrors `TestSetupRow` from the student
/// dashboard, with the staff-only actions added.
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
    let resetPath: String
    let historyURL: String
    let latest: LatestSubmissionCell
    let gradeOverridePercent: Int  // form prefill; 0 when no override is set
    let gradeOverrideSavePath: String
    let gradeOverrideClearPath: String
    let badges: [AchievementBadge]
}

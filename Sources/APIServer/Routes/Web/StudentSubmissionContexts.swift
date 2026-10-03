// APIServer/Routes/Web/StudentSubmissionContexts.swift
//
// Leaf view-context types for the per-student submission views (both the
// instructor-facing per-assignment-per-student history and the
// course-scoped grouped view).  Split from the original
// `AssignmentContextTypes.swift`.

import Foundation

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

    /// The ungrouped rows in the same shape a section has, so the rows partial
    /// can be rendered from one definition for both cases (it reads `rows`).
    /// STORED, not computed: a synthesized `Encodable` only encodes stored
    /// properties, so a computed one is simply absent from the render context
    /// and Leaf fails with "expressions should resolve to a single dictionary
    /// value".
    let ungroupedRowsContext: StudentAssignmentRowsContext
}

/// The one thing `_student-assignment-rows.leaf` needs. A section already
/// satisfies this shape, so it is passed directly.
struct StudentAssignmentRowsContext: Encodable {
    let rows: [StudentAssignmentRow]
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
    let resetPath: String
    let historyURL: String
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
    let gradeIsOverridden: Bool
    let gradeOverridePercent: Int  // form prefill; 0 when no override is set
    let gradeOverrideSavePath: String
    let gradeOverrideClearPath: String
    let badges: [AchievementBadge]
}

/// One student's full submission history on one assignment, for course
/// staff (`student-assignment-history.leaf`). Two routes render it: the
/// assignment's roster (`/instructor/:assignmentID/students/:studentID/history`)
/// and the course's per-student view. They differ only in where the back link
/// goes and whether rows link to their diff, so that is all they pass
/// differently (#1710).
struct StudentAssignmentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    /// `accountIdentityName`: the display name, else the preferred name, else
    /// the username.
    let studentName: String
    /// Nil when it would repeat `studentName` (`accountIdentitySecondary`).
    let studentUsername: String?
    let assignmentID: String
    let assignmentTitle: String
    let backURL: String
    let backLabel: String
    /// Whether each row links to its diff against the starter. Only the
    /// roster route offers it: the diff page's History link returns to the
    /// roster's copy of this page, so from the course route it would drop
    /// the reader's way back to the student.
    let showsDiff: Bool
    /// This page's path, sent as a retest's `returnTo`. Only the roster
    /// route's path comes back here: `sanitizedAssignmentReturnPath` accepts
    /// `/instructor/<id>` paths only, so a retest from the course route lands
    /// on the roster's submissions page.
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}

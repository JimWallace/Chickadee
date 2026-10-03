// APIServer/Routes/Web/LatestSubmissionCell.swift
//
// The "latest submission" cell that three rows render: the student
// dashboard's `TestSetupRow`, the course's per-student `StudentAssignmentRow`
// and the assignment roster's `AssignmentStudentRow`. Each builder used to
// spell the same rules — the count of other submissions, the empty ID, the
// em-dash, an override before the best grade — and one place now holds them
// (#1711).

/// How many submissions a student has on an assignment, a link to the newest
/// one, and the grade that counts.
struct LatestSubmissionCell: Encodable {
    let submissionCount: Int
    let hasLatestSubmission: Bool
    /// Empty when there is no submission.
    let latestSubmissionID: String
    /// An em-dash when there is no submission, or no time on it.
    let latestSubmittedAtText: String
    /// The submissions other than the latest, for the "+N more" link.
    let additionalSubmissionCount: Int
    /// The override when one is set, else the best grade; nil when neither.
    let bestGradeText: String?
    /// True when `bestGradeText` is an instructor override rather than the
    /// runner-computed grade.
    let gradeIsOverridden: Bool

    init(
        count: Int, latestSubmissionID: String?, latestSubmittedAtText: String?,
        bestPercent: Int?, overridePercent: Int?
    ) {
        submissionCount = count
        hasLatestSubmission = latestSubmissionID != nil
        self.latestSubmissionID = latestSubmissionID ?? ""
        self.latestSubmittedAtText = latestSubmittedAtText ?? "—"
        additionalSubmissionCount = max(count - 1, 0)
        bestGradeText = (overridePercent ?? bestPercent).map { "\($0)%" }
        gradeIsOverridden = overridePercent != nil
    }
}

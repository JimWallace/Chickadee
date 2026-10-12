// APIServer/Views/Pages/StudentAssignmentHistoryPage.swift
//
// One student's full submission history on one assignment, for course staff.
// Two routes render it: the assignment's roster
// (`/instructor/:assignmentID/students/:studentID/history`) and the course's
// per-student view. They differ only in where the back link goes and whether
// rows link to their diff, so that is all they pass differently (#1710).

import Elementary

struct StudentAssignmentHistoryPage: HTML {
    let page: PageRequestContext
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

    var body: some HTML {
        BaseLayout(title: "\(studentName) — \(assignmentTitle)", page: page) {
            div(.class("page-titlebar page-titlebar--baseline")) {
                div {
                    h1 { assignmentTitle }
                    p(.class("titlebar-subtitle")) {
                        strong { studentName }
                        if let studentUsername { " (\(studentUsername))" }
                    }
                }
                a(.class("btn action-btn"), .href(backURL)) { backLabel }
            }
            if rows.isEmpty {
                p(.class("empty")) { "No submissions yet for this student on this assignment." }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th { "Attempt" }
                            th { "Status" }
                            th { "Submitted" }
                            th { "Grade" }
                            th { "Details" }
                            th { "Action" }
                        }
                    }
                    tbody {
                        for row in rows {
                            StudentAssignmentHistoryRow(
                                row: row, assignmentID: assignmentID, showsDiff: showsDiff,
                                historyPath: historyPath, csrfToken: page.csrfToken)
                        }
                    }
                }
            }
        }
    }
}

/// One submission, with its results and diff links and the retest action.
struct StudentAssignmentHistoryRow: HTML {
    let row: AssignmentSubmissionHistoryRow
    let assignmentID: String
    let showsDiff: Bool
    let historyPath: String
    let csrfToken: String

    var body: some HTML {
        tr {
            td { "\(row.attemptNumber)" }
            td { span(.class("tier")) { row.status } }
            td { row.submittedAt }
            td { strong { row.gradeText } }
            td {
                a(
                    .class("btn action-btn action-btn-icon"), .href("/submissions/\(row.submissionID)"),
                    .title("View results"), .ariaLabel("View results")
                ) {
                    Icon("i-eye")
                }
                if showsDiff {
                    a(
                        .class("btn action-btn action-btn-icon"),
                        .href("/instructor/\(assignmentID)/submissions/\(row.submissionID)/diff"),
                        .title("Diff against starter"), .ariaLabel("Diff against starter")
                    ) {
                        Icon("i-diff")
                    }
                }
            }
            td {
                form(
                    .method(.post), .action("/instructor/\(assignmentID)/submissions/\(row.submissionID)/retest"),
                    .data("confirm", value: "Send this submission back to the testing queue?"),
                    .class("inline-form")
                ) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("returnTo"), .value(historyPath))
                    button(
                        .class("btn action-btn action-btn-icon"), .type(.submit), .title("Re-test submission"),
                        .ariaLabel("Re-test submission")
                    ) {
                        Icon("i-refresh")
                    }
                }
            }
        }
    }
}

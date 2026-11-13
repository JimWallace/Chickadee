// APIServer/Views/Pages/SubmissionHistoryPage.swift
//
// GET /testsetups/:testSetupID/history: a student's own submissions to one
// assignment, newest first.

import Elementary

struct SubmissionHistoryPage: HTML {
    let page: PageRequestContext
    let assignmentTitle: String
    let rows: [SubmissionHistoryRow]

    var body: some HTML {
        BaseLayout(title: "\(assignmentTitle) — History", page: page) {
            div(.class("page-titlebar")) {
                h1 { assignmentTitle }
                a(.class("btn action-btn"), .href("/")) { "Dashboard" }
            }
            if rows.isEmpty {
                p(.class("empty")) { "No submissions yet for this assignment." }
            } else {
                table(.class("results-table")) {
                    thead {
                        tr {
                            th(.class("col-hide-phone")) { "Attempt" }
                            th { "Submitted" }
                            th { "Status" }
                            th { "Grade" }
                            th { "Actions" }
                        }
                    }
                    tbody {
                        for row in rows {
                            SubmissionHistoryTableRow(row: row)
                        }
                    }
                }
            }
            PageStyle(
                """
                .history-actions {
                    display: flex;
                    gap: .4rem;
                    flex-wrap: wrap;
                    align-items: center;
                }
                """
            )
        }
    }
}

/// One submission, with its view, download and notebook links.
struct SubmissionHistoryTableRow: HTML {
    let row: SubmissionHistoryRow

    var body: some HTML {
        let history = row.history
        tr {
            td(.class("col-hide-phone")) { "\(history.attemptNumber)" }
            SubmittedAtCell(row: history)
            td { span(.class("tier")) { SubmissionStatus.displayLabel(forRaw: history.status) } }
            td { history.gradeText }
            td {
                div(.class("history-actions")) {
                    a(
                        .class("btn action-btn action-btn-icon"), .href("/submissions/\(history.submissionID)"),
                        .title("View results"), .ariaLabel("View results")
                    ) {
                        Icon("i-eye")
                    }
                    a(
                        .class("btn action-btn action-btn-icon"),
                        .href("/api/v1/submissions/\(history.submissionID)/download"),
                        .title("Download submission"), .ariaLabel("Download submission")
                    ) {
                        Icon("i-download")
                    }
                    if row.canOpenInNotebook {
                        a(
                            .class("btn action-btn action-btn-icon"), .href(row.openInNotebookURL ?? ""),
                            .title("Open in notebook"), .ariaLabel("Open in notebook")
                        ) {
                            Icon("i-notebook")
                        }
                    }
                }
            }
        }
    }
}

/// A history row's submit time: relative, with the server's absolute text as
/// the no-JS fallback (docs/ui-design.md §"Timestamps").
struct SubmittedAtCell: HTML {
    let row: AssignmentSubmissionHistoryRow

    var body: some HTML {
        if let iso = row.submittedAtISO {
            td(.class("js-relative-time"), .data("iso", value: iso)) { row.submittedAt }
        } else {
            td { row.submittedAt }
        }
    }
}

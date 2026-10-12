// APIServer/Views/Pages/SubmissionDiffPage.swift
//
// GET /instructor/:assignmentID/submissions/:submissionID/diff: what a
// student changed against the assignment's starter, as a unified listing.

import Core
import Elementary

struct SubmissionDiffPage: HTML {
    let page: PageRequestContext
    let assignmentTitle: String
    /// The same identity line as the history page this is reached from.
    let studentName: String
    /// Nil when it would repeat `studentName` (`accountIdentitySecondary`).
    let studentUsername: String?
    let attemptNumber: Int
    let comparedLabel: String
    /// Set when the submission has no comparable text; shown instead of the listing.
    let unavailableReason: String?
    let rows: [LineDiffRow]
    let resultsURL: String
    let historyURL: String

    var body: some HTML {
        BaseLayout(title: "\(studentName) — \(assignmentTitle) diff", page: page) {
            div(.class("page-titlebar page-titlebar--baseline")) {
                div {
                    h1 { assignmentTitle }
                    p(.class("titlebar-subtitle")) {
                        strong { studentName }
                        if let studentUsername { " (\(studentUsername))" }
                        " · attempt \(attemptNumber) · \(comparedLabel)"
                    }
                }
                div(.class("toolbar")) {
                    a(.class("btn action-btn"), .href(resultsURL)) { "Results" }
                    a(.class("btn action-btn"), .href(historyURL)) { "History" }
                }
            }
            if let unavailableReason {
                p(.class("empty")) { unavailableReason }
            } else {
                listing
            }
        }
    }

    @HTMLBuilder private var listing: some HTML {
        let counts = LineDiff.counts(rows)
        div(.class("chip-row section-gap")) {
            span(.class("chip chip-ok")) { "+\(counts.added) added" }
            span(.class("chip chip-err")) { "−\(counts.removed) removed" }
        }
        if rows.isEmpty {
            p(.class("empty")) { "The submission is identical to the starter." }
        } else {
            div(.class("table-scroll")) {
                table(.class("diff-table")) {
                    tbody {
                        for row in rows {
                            SubmissionDiffRow(row: row)
                        }
                    }
                }
            }
        }
    }
}

/// One listing row: added, removed, context or a fold, with the notebook
/// cell boundary marked.
struct SubmissionDiffRow: HTML {
    let row: LineDiffRow

    private var rowClass: String {
        let kind =
            switch row.kind {
            case .added: "diff-added"
            case .removed: "diff-removed"
            case .fold: "diff-fold"
            case .context: "diff-context"
            }
        let isMarker = row.kind != .fold && row.text == notebookDiffCellMarker
        return isMarker ? "\(kind) diff-marker" : kind
    }

    private func number(_ value: Int?) -> String {
        row.kind == .fold ? "" : value.map(String.init) ?? ""
    }

    var body: some HTML {
        tr(.class(rowClass)) {
            td(.class("diff-gutter")) { number(row.oldNumber) }
            td(.class("diff-gutter")) { number(row.newNumber) }
            td(.class("diff-line")) { row.text }
        }
    }
}

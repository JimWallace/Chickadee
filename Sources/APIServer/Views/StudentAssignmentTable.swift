// APIServer/Views/StudentAssignmentTable.swift
//
// One student's assignments, with the staff row actions, on the course's
// per-student submissions page (`CourseStudentSubmissionsPage`). The page
// draws it once per course section and once for the ungrouped assignments,
// from this one definition (UI audit S7).

import Elementary

/// One student's assignment rows: status, due date, grade, history and the
/// retest, extension, grade-override and reset actions.
struct StudentAssignmentTable: HTML {
    let rows: [StudentAssignmentRow]
    let csrfToken: String

    var body: some HTML {
        table(.class("results-table")) {
            thead {
                tr {
                    th { "Name" }
                    th { "Status" }
                    th(.class("due-col col-hide-phone")) { "Due" }
                    th { "Grade" }
                    th(.class("col-hide-phone")) { "History" }
                    th { "Actions" }
                }
            }
            tbody {
                for row in rows {
                    StudentAssignmentTableRow(row: row, csrfToken: csrfToken)
                }
            }
        }
    }
}

private struct StudentAssignmentTableRow: HTML {
    let row: StudentAssignmentRow
    let csrfToken: String

    private var statusClass: String {
        switch row.status {
        case "open": "tier tier-open"
        case "closed": "tier tier-closed"
        default: "tier"
        }
    }

    var body: some HTML {
        tr {
            td {
                div(.class("assignment-title-cell")) {
                    strong { row.title }
                    if !row.badges.isEmpty {
                        " "
                        span(.class("achievement-badges achievement-badges-compact")) {
                            for badge in row.badges {
                                " "
                                span(.class("achievement-badge achievement-badge-compact"), .title(badge.tooltip)) {
                                    badge.label
                                }
                            }
                            " "
                        }
                    }
                }
            }
            td { span(.class(statusClass)) { row.status } }
            td(.class("due-col col-hide-phone")) { dueCell }
            td { gradeCell }
            td(.class("col-hide-phone")) {
                SubmissionHistoryLinks(latest: row.latest, historyURL: row.historyURL)
            }
            td {
                div(.class("row-actions-tight")) {
                    if row.latest.submissionCount > 0 {
                        form(
                            .method(.post), .action(row.retestPath),
                            .data("confirm", value: "Re-test all of this student’s submissions on this assignment?"),
                            .class("form-flush")
                        ) {
                            CSRFField(token: csrfToken)
                            " "
                            button(
                                .class("btn action-btn action-btn-icon"), .type(.submit),
                                .ariaLabel("Re-test this student’s submissions"),
                                .title("Re-test every submission this student has on this assignment")
                            ) {
                                " "
                                Icon("i-refresh")
                                " "
                            }
                        }
                    }
                    extensionMenu
                    gradeOverrideMenu
                    form(
                        .method(.post), .action(row.resetPath),
                        .data(
                            "confirm",
                            value:
                                "Reset this student’s working-copy notebook back to the original assignment starter? Past submissions are not affected. The student will see the fresh starter automatically on their next visit."
                        ),
                        .class("form-flush")
                    ) {
                        CSRFField(token: csrfToken)
                        " "
                        button(
                            .class("btn action-btn action-btn-icon action-danger"), .type(.submit),
                            .ariaLabel("Reset this student’s working notebook"),
                            .title("Reset this student’s working-copy notebook to the original starter")
                        ) {
                            " "
                            Icon("i-rewind")
                            " "
                        }
                    }
                }
            }
        }
    }

    @HTMLBuilder private var dueCell: some HTML {
        if let effective = row.effectiveDueAtText {
            effective
            br()
            span(.class("card-meta")) { "+ extension" }
            br()
            if let due = row.dueAtText {
                span(.class("card-meta")) { "class due \(due)" }
            } else {
                span(.class("card-meta")) { "no class due date" }
            }
        } else if let due = row.dueAtText {
            due
        } else {
            "—"
        }
    }

    @HTMLBuilder private var gradeCell: some HTML {
        if let grade = row.latest.bestGradeText {
            strong { grade }
            if row.latest.gradeIsOverridden {
                " "
                span(.class("grade-override-tag"), .title("Grade manually overridden by an instructor")) {
                    "overridden"
                }
            }
        } else {
            span(.class("empty")) { "—" }
        }
    }

    private var extensionMenu: some HTML {
        details(.class("ext-details form-flush")) {
            summary(
                .class("btn action-btn action-btn-icon ext-summary"),
                .title(
                    row.hasExtension
                        ? "Edit this student’s deadline extension" : "Grant this student a deadline extension"),
                .ariaLabel(row.hasExtension ? "Edit deadline extension" : "Grant deadline extension")
            ) {
                Icon(row.hasExtension ? "i-calendar-check" : "i-calendar")
            }
            form(.method(.post), .action(row.extensionSavePath), .class("popover-panel")) {
                CSRFField(token: csrfToken)
                " "
                label(.class("ext-field-label")) {
                    "New deadline for this student"
                    input(
                        .type(.datetimeLocal), .name("extendedDueAt"), .value(row.extensionFormInput), .required,
                        .class("ext-field-input"))
                    " "
                }
                " "
                label(.class("ext-field-label")) {
                    "Note (optional)"
                    input(
                        .type(.text), .name("note"), .placeholder("Reason for extension"), .class("ext-field-input"))
                    " "
                }
                div(.class("ext-panel-actions")) {
                    button(.class("btn action-btn"), .type(.submit)) { "Save" }
                    if row.hasExtension {
                        " "
                        button(
                            .class("btn action-btn"), .type(.submit),
                            .custom(name: "formaction", value: row.extensionDeletePath),
                            .init(name: "formnovalidate", value: nil),
                            .data("confirm", value: "Remove this student’s extension on this assignment?")
                        ) { "Remove" }
                    }
                }
            }
        }
    }

    private var gradeOverrideMenu: some HTML {
        GradeOverrideMenu(
            isOverridden: row.latest.gradeIsOverridden, percent: row.gradeOverridePercent,
            savePath: row.gradeOverrideSavePath, clearPath: row.gradeOverrideClearPath,
            panelClass: "popover-panel", returnTo: nil, csrfToken: csrfToken)
    }
}

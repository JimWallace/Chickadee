// APIServer/Views/Pages/AssignmentSubmissionsPage.swift
//
// GET /instructor/:assignmentID/submissions: the assignment's roster with each
// student's grade and latest submission, the stat cards, and, where they
// apply, the class coverage and tournament sections.

import Elementary

struct AssignmentSubmissionsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let assignmentID: String
    let assignmentTitle: String
    let metrics: [AssignmentStatCard]
    let rows: [AssignmentStudentRow]
    /// The assignment's secret-reveal toggle. Gates the spent tag and the
    /// re-grant action.
    let secretRevealEnabled: Bool
    /// True when both AI-assisted feedback gates are on; shows the link to the
    /// review page.
    let aiFeedbackOpen: Bool
    /// One row per suite item of a contribution assignment; empty otherwise,
    /// which keeps the coverage section off the page.
    let coverageRows: [AssignmentCoverageRow]
    /// "9 / 15 items found".
    let coverageSummary: String
    let tournament: TournamentControlFacts

    private var returnTo: String { "/instructor/\(assignmentID)/submissions" }

    var body: some HTML {
        BaseLayout(title: "\(assignmentTitle) — Submissions", page: page, flash: flash) {
            div(.class("page-titlebar")) {
                h1 { assignmentTitle }
                if aiFeedbackOpen {
                    a(.class("btn action-btn"), .href("/instructor/\(assignmentID)/feedback")) { "AI feedback" }
                }
            }
            section(.class("diagnostics-section")) {
                DiagnosticCards(metrics: metrics)
            }
            if !coverageRows.isEmpty {
                coverageSection
            }
            if tournament.isTournamentKind {
                tournamentSection
            }
            if rows.isEmpty {
                p(.class("empty")) { "No student users found." }
            } else {
                div(.class("toolbar toolbar--end section-gap")) {
                    a(
                        .class("btn action-btn"), .href("/instructor/\(assignmentID)/submissions.zip"),
                        .title("Download every student's latest submission")
                    ) { "Download all" }
                    " "
                    span(.class("filter-group")) {
                        " "
                        label(.class("filter-label"), .for("submissions-filter")) { "Filter" }
                        " "
                        input(
                            .id("submissions-filter"), .class("form-input filter-input"), .type(.search),
                            .placeholder("Filter by name or ID…"),
                            .data("list-filter", value: "assignment-submissions-table"),
                            .data("list-filter-empty", value: "No submissions match this filter."))
                        " "
                    }
                }
                table(
                    .class("results-table sortable-table"), .id("assignment-submissions-table"),
                    .data("sort-initial", value: "history:desc"), .data("sort-tiebreak", value: "surname")
                ) {
                    thead {
                        tr {
                            SortHeader(key: "surname", type: "text", label: "Surname")
                            SortHeader(key: "given_names", type: "text", label: "Given Names")
                            SortHeader(key: "student_id", type: "text", label: "Student ID", hideOnPhone: true)
                            SortHeader(key: "grade", type: "number", label: "Grade")
                            SortHeader(key: "history", type: "date", label: "History", hideOnPhone: true)
                            th { "Action" }
                        }
                    }
                    tbody {
                        for row in rows {
                            AssignmentSubmissionsRow(
                                row: row, assignmentID: assignmentID, secretRevealEnabled: secretRevealEnabled,
                                returnTo: returnTo, csrfToken: page.csrfToken)
                        }
                    }
                }
            }
            PageStyle(
                """
                .subm-row-actions {
                    display: flex;
                    gap: .2rem;
                    flex-wrap: wrap;
                    align-items: center;
                }
                """
            )
            script(.src(page.asset("/list-filter.js"))) {}
            script(.src(page.asset("/sortable-table.js"))) {}
            // The submissions trend card is wired by
            // Public/assignment-submissions.js.
            script(.src(page.asset("/assignment-submissions.js"))) {}
        }
    }

    private var coverageSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Class coverage" }
                span(.class("chip")) { coverageSummary }
            }
            table(.class("results-table")) {
                thead {
                    tr {
                        th { "Item" }
                        th { "Status" }
                        th { "First found by" }
                        th(.class("time col-hide-phone")) { "When" }
                    }
                }
                tbody {
                    for row in coverageRows {
                        tr {
                            td { code { row.item } }
                            td {
                                if row.found {
                                    span(.class("tier tier-open")) { "found" }
                                } else {
                                    span(.class("tier tier-closed")) { "not yet found" }
                                }
                            }
                            td { row.found ? row.foundBy : "—" }
                            td(.class("time col-hide-phone")) { row.found ? row.foundAt : "—" }
                                .attributes(
                                    .class("js-relative-time"), .data("iso", value: row.foundAtISO), when: row.found)
                        }
                    }
                }
            }
        }
    }

    /// The run control. For a per-group activity it names the lab group whose
    /// session plays (docs/lab-groups.md, slice 3d).
    private var runForm: some HTML {
        form(.method(.post), .action("/instructor/\(assignmentID)/tournament/run"), .class("form-stack")) {
            CSRFField(token: page.csrfToken)
            " "
            label(.class("form-label")) {
                "Schedule"
                select(.class("form-input"), .name("schedule")) {
                    for option in tournament.scheduleOptions {
                        Elementary.option(.value(option.value)) { option.label }
                            .attributes(.selected, when: option.selected)
                    }
                }
                " "
            }
            if tournament.isPerGroup {
                label(.class("form-label")) {
                    "Lab group"
                    select(.class("form-input"), .name("group")) {
                        for group in tournament.groupOptions {
                            option(.value(group.id)) { group.name }
                        }
                    }
                    " "
                }
                p(.class("field-note field-note--muted")) {
                    "The students who joined the group's session enter, seeded in submission order."
                }
            } else {
                p(.class("field-note field-note--muted")) {
                    "Every student's latest complete submission enters, seeded in submission order."
                }
            }
            button(.class("btn btn-primary"), .type(.submit)) { "Run tournament" }
        }
        .attributes(.data("confirm", value: tournament.supersedeConfirm), when: tournament.hasRunInProgress)
    }

    private var tournamentSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Tournament" }
                a(.class("btn action-btn"), .href(tournament.leaderboardURL)) { "Open bracket" }
            }
            if tournament.isPerGroup && tournament.groupOptions.isEmpty {
                // A per-group tournament with no group to play it.
                p(.class("section-intro")) {
                    "This course has no lab groups yet; "
                    a(.href("/instructor/groups")) { "add them on the Groups tab" }
                    "."
                }
            } else {
                p(.class("section-intro")) { tournament.statusText }
                runForm
            }
        }
    }
}

/// One student: name, ID, grade, latest submission and the row actions.
private struct AssignmentSubmissionsRow: HTML {
    let row: AssignmentStudentRow
    let assignmentID: String
    let secretRevealEnabled: Bool
    let returnTo: String
    let csrfToken: String

    private var studentPath: String { "/instructor/\(assignmentID)/students/\(row.studentUUID)" }

    var body: some HTML {
        tr {
            td { row.surname }
            td { row.givenNames }
            td(.class("col-hide-phone"), .data("sort-value", value: row.studentID)) {
                strong { row.studentID }
                if secretRevealEnabled && row.secretRevealSpent {
                    " "
                    span(.class("tier")) { "Secret tests revealed" }
                }
            }
            td {
                row.gradeText
                if row.latest.gradeIsOverridden {
                    span(.class("grade-override-tag"), .title("Grade manually overridden by an instructor")) {
                        "overridden"
                    }
                }
                if let passingLabel = row.passingLabel {
                    " "
                    span(.class(row.isPassing ? "tier tier-open" : "tier tier-closed")) { passingLabel }
                }
            }
            td(.class("col-hide-phone"), .data("sort-value", value: String(row.latestSubmittedAtEpoch))) {
                SubmissionHistoryLinks(latest: row.latest, historyURL: row.fullHistoryURL)
            }
            td { actions }
        }
    }

    private var actions: some HTML {
        div(.class("subm-row-actions")) {
            if row.latest.hasLatestSubmission {
                RowActionForm(
                    action: "/instructor/\(assignmentID)/submissions/\(row.latest.latestSubmissionID)/retest",
                    confirm: "Send this submission back to the testing queue?", returnTo: returnTo,
                    buttonClass: "btn action-btn action-btn-icon", label: "Re-test latest submission",
                    title: "Re-test latest submission", icon: "i-refresh", csrfToken: csrfToken)
            }
            GradeOverrideMenu(
                isOverridden: row.latest.gradeIsOverridden, percent: row.gradeOverridePercent,
                savePath: "\(studentPath)/grade-override", clearPath: "\(studentPath)/grade-override/delete",
                panelClass: "ext-panel", returnTo: returnTo, csrfToken: csrfToken)
            RowActionForm(
                action: "\(studentPath)/reset-notebook",
                confirm:
                    "Reset this student’s working-copy notebook back to the original assignment starter? Past submissions are not affected. The student will see the fresh starter automatically on their next visit.",
                returnTo: returnTo, buttonClass: "btn action-btn action-btn-icon action-danger",
                label: "Reset notebook to starter", title: "Reset notebook to starter (past submissions unaffected)",
                icon: "i-rewind", csrfToken: csrfToken)
            if secretRevealEnabled && row.secretRevealSpent {
                RowActionForm(
                    action: "\(studentPath)/regrant-reveal-token",
                    confirm:
                        "Re-grant this student’s secret-reveal token? Secret test results will be hidden from them again until they spend it.",
                    returnTo: returnTo, buttonClass: "btn action-btn action-btn-icon",
                    label: "Re-grant secret-reveal token",
                    title: "Re-grant secret-reveal token (student spent theirs)", icon: "i-lock",
                    csrfToken: csrfToken)
            }
        }
    }
}

/// A confirmed one-button POST that returns to the roster.
private struct RowActionForm: HTML {
    let action: String
    let confirm: String
    let returnTo: String
    let buttonClass: String
    let label: String
    let title: String
    let icon: String
    let csrfToken: String

    var body: some HTML {
        form(.method(.post), .action(action), .data("confirm", value: confirm), .class("form-flush")) {
            CSRFField(token: csrfToken)
            " "
            input(.type(.hidden), .name("returnTo"), .value(returnTo))
            " "
            button(.class(buttonClass), .type(.submit), .ariaLabel(label), .title(title)) {
                " "
                Icon(icon)
                " "
            }
        }
    }
}

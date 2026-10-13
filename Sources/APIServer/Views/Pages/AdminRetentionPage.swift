// APIServer/Views/Pages/AdminRetentionPage.swift
//
// GET /admin/retention: the Data > Retention tab. Every archived course, with
// restore, export and (once the retention window has passed) delete.

import Elementary

struct AdminRetentionPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let retentionDays: Int
    /// Server order: delete-eligible courses first, then the soonest to become
    /// eligible.
    let rows: [AdminRetentionRow]

    private var deletableCount: Int { rows.filter(\.isDeletable).count }

    var body: some HTML {
        BaseLayout(title: "Retention", page: page, flash: flash) {
            AdminTabs(active: .retention, page: page)
            section(.class("page-section")) {
                p(.class("page-crumb")) { "Data" }
                div(.class("page-titlebar")) {
                    h2 {
                        "Retention "
                        span(.class("text-muted")) { "\(rows.count) archived · \(deletableCount) eligible to delete" }
                    }
                }
                p(.class("section-intro")) {
                    "Archived courses can be restored at any time. \(retentionDays) days after archiving, "
                    "an admin may permanently delete one, which can’t be undone."
                }
                if rows.isEmpty {
                    p(.class("text-muted")) {
                        "No archived courses. The retention clock starts when a course is archived."
                    }
                } else {
                    table(.class("results-table section-items section-items--manage")) {
                        colgroup {
                            col(.class("section-items-tile"))
                            col()
                            col(.class("section-items-status"))
                            col(.class("section-items-actions"))
                        }
                        thead(.class("visually-hidden")) {
                            tr {
                                for heading in ["Course", "Detail", "Status", "Actions"] {
                                    th(.custom(name: "scope", value: "col")) { heading }
                                }
                            }
                        }
                        tbody {
                            for row in rows {
                                AdminRetentionCourseRow(row: row, csrfToken: page.csrfToken)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One archived course, with its restore, export and delete actions.
private struct AdminRetentionCourseRow: HTML {
    let row: AdminRetentionRow
    let csrfToken: String

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) { span(.class("item-tile")) { Icon("i-archive") } }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    a(.href("/admin/courses/\(row.id)")) { strong { row.code } }
                    " — \(row.name)"
                }
                div(.class("item-details")) {
                    if let term = row.termLabel { "\(term) · " }
                    " archived \(row.archivedAt) · \(row.submissionCount) submissions"
                }
            }
            td(.class("item-status")) {
                if row.isDeletable {
                    span(.class("tier tier-danger")) { "Eligible to delete" }
                } else {
                    span(.class("tier tier-closed")) { "Deletable \(row.purgeEligibleAt)" }
                }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    form(.method(.post), .action("/admin/courses/\(row.id)/archive"), .class("inline-form")) {
                        CSRFField(token: csrfToken)
                        button(
                            .class("btn action-btn action-btn-icon"), .type(.submit),
                            .title("Restore course"), .ariaLabel("Restore \(row.code)"),
                            .data(
                                "confirm",
                                value: "Restore \(row.code)? Students regain access immediately. "
                                    + "Its submissions are kept and the retention clock stops.")
                        ) {
                            Icon("i-rewind")
                        }
                    }
                    a(
                        .class("btn action-btn action-btn-icon"), .href("/admin/courses/\(row.id)/export"),
                        .title("Export course bundle"), .ariaLabel("Export \(row.code)")
                    ) {
                        Icon("i-download")
                    }
                    if row.isDeletable {
                        deleteMenu
                    } else {
                        span(.class("row-menu-spacer"), .ariaHidden) {}
                    }
                }
            }
        }
    }

    private var deleteMenu: some HTML {
        RowMenu(for: row.code) {
            form(
                .method(.post), .action("/admin/courses/\(row.id)/delete"),
                .data(
                    "confirm",
                    value: "Permanently delete \(row.code)? Its course record, assignments, test suites "
                        + "and every submission are erased. This cannot be undone.")
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-trash")
                    "Delete course permanently"
                }
            }
        }
    }
}

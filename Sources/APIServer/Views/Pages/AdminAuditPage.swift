// APIServer/Views/Pages/AdminAuditPage.swift
//
// GET /admin/audit: the Data > Audit Log tab. Sensitive admin actions,
// sign-ins and agent activity, newest first, filtered by action and actor.

import Elementary

struct AdminAuditPage: HTML {
    let page: PageRequestContext
    /// The newest matching entries under day headings, newest first.
    let days: [DayGroup<AdminAuditRow>]
    /// Available action filters (grouped label shown to the admin).
    let actionOptions: [SelectOption]
    /// The actor substring currently filtered on (echoed back into the input).
    let filterActor: String
    /// True when any filter is active: drives the Clear link.
    let filtered: Bool
    /// Total entries matching the current filter (may exceed the 200 shown).
    let matchCount: Int

    private var shownCount: Int { days.reduce(0) { $0 + $1.rows.count } }

    var body: some HTML {
        BaseLayout(title: "Audit Log", page: page) {
            AdminTabs(active: .audit, page: page)
            section(.class("page-section")) {
                p(.class("page-crumb")) { "Data" }
                div(.class("page-titlebar")) {
                    h2 { "Audit log" }
                }
                p(.class("section-intro")) {
                    "Sensitive admin actions, sign-ins and agent (MCP / OAuth) activity. "
                    "Older entries stay in the database."
                }
                filterForm
                if shownCount == 0 {
                    p(.class("text-muted")) {
                        filtered ? "No audit entries match this filter." : "No audit entries recorded yet."
                    }
                } else {
                    p(.class("text-muted")) {
                        "Showing the newest \(shownCount) of \(matchCount) matching "
                        "\(matchCount == 1 ? "entry" : "entries")."
                    }
                    // The log/event shape: who, what, how it went, and when.
                    // Each entry is one disclosure: its summary is the row, and
                    // the panel under it holds category, target, remote address
                    // and metadata. Deliberately not a sortable-table: the
                    // server sends the most recent 200 of matchCount, newest
                    // first, so a client-side re-sort would offer "oldest" rows
                    // that are only the oldest of that window.
                    table(.class("results-table section-items section-items--manage")) {
                        thead(.class("visually-hidden")) {
                            tr { th(.custom(name: "scope", value: "col")) { "Entries" } }
                        }
                        tbody {
                            for day in days {
                                tr(.class("section-items-heading")) {
                                    td { strong { day.label } }
                                }
                                for row in day.rows {
                                    AdminAuditEntryRow(row: row)
                                }
                            }
                        }
                    }
                }
            }
            PageStyle(
                """
                /* Forensic instant: mono, over the relative reading. */
                .log-when-absolute {
                    display: block;
                    font-family: var(--font-mono);
                    font-size: var(--text-sm);
                    color: var(--gray-600);
                }
                .audit-metadata {
                    font-family: var(--font-mono);
                    font-size: var(--text-sm);
                    white-space: pre-wrap;
                    word-break: break-word;
                }
                """
            )
            script(.src(page.asset("/list-filter.js"))) {}
        }
    }

    private var filterForm: some HTML {
        form(.method(.get), .action("/admin/audit"), .class("toolbar section-gap")) {
            label(.class("field-inline")) {
                span(.class("visually-hidden")) { "Action" }
                select(.name("action"), .class("form-input input-compact"), .dataFlag("ck-submit-on-change")) {
                    option(.value("")) { "All actions" }
                    for option in actionOptions {
                        Elementary.option(.value(option.value)) { option.label }
                            .attributes(.selected, when: option.selected)
                    }
                }
            }
            span(.class("filter-group")) {
                label(.class("filter-label"), .for("audit-actor")) { "Person" }
                input(
                    .id("audit-actor"), .class("form-input filter-input"), .type(.search),
                    .name("actor"), .value(filterActor), .placeholder("username"))
            }
            if filtered {
                a(.class("btn action-btn"), .href("/admin/audit")) { "Clear" }
            }
            noscript {
                button(.type(.submit), .class("btn action-btn")) { "Filter" }
            }
        }
    }
}

/// One audit entry: a disclosure whose summary is the row.
private struct AdminAuditEntryRow: HTML {
    let row: AdminAuditRow

    var body: some HTML {
        tr {
            td(.class("log-entry-cell")) {
                details(.class("log-entry")) {
                    summary {
                        span(.class("item-tile"), .data("kind", value: row.tileKind)) {
                            SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(row.iconHref)) {} }
                        }
                        span {
                            span(.class("item-title")) {
                                strong { row.actor }
                                " \(row.label)"
                            }
                            span(.class("item-details")) {
                                code { row.action }
                                if let targetType = row.targetType {
                                    " · \(targetType)"
                                    if let targetID = row.targetID { " \(targetID)" }
                                }
                                " · \(row.remoteAddr)"
                            }
                        }
                        span(.class("tier \(row.outcomeTier)")) { row.outcome }
                        span(.class("log-entry-when")) {
                            span(.class("log-when-absolute")) { row.clockText }
                            span(.class("item-details js-relative-time"), .data("iso", value: row.timestampISO)) {}
                        }
                        Icon("i-chevron-down")
                    }
                    dl(.class("detail-grid log-payload")) {
                        dt { "Category" }
                        dd { row.category }
                        dt { "Target" }
                        dd {
                            if let targetType = row.targetType {
                                targetType
                                if let targetID = row.targetID {
                                    " · "
                                    code { targetID }
                                }
                            } else {
                                "—"
                            }
                        }
                        dt { "Remote" }
                        dd { code { row.remoteAddr } }
                        dt { "Metadata" }
                        dd(.class("audit-metadata")) { row.metadata.isEmpty ? "—" : row.metadata }
                    }
                }
            }
        }
    }
}

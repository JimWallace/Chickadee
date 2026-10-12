// APIServer/Views/Pages/AdminStoragePage.swift
//
// GET /admin/storage: the Data > Storage tab. The on-disk footprint by
// component, then by assignment, largest first.

import Elementary

struct AdminStoragePage: HTML {
    let page: PageRequestContext
    let storage: AdminStorageContext
    /// Already largest first, so the list is not sortable.
    let assignmentRows: [AdminStorageShareRow]

    var body: some HTML {
        BaseLayout(title: "Storage", page: page) {
            AdminTabs(active: .storage, page: page)
            section(.class("diagnostics-section")) {
                p(.class("page-crumb")) { "Data" }
                div(.class("page-titlebar")) {
                    h2 {
                        "Storage "
                        span(.class("text-muted")) { "\(storage.totalFormatted) total · \(storage.dbBackend)" }
                    }
                }
                div(.class("diagnostics-cards")) {
                    for row in storage.rows {
                        StorageCard(label: row.label, value: row.formatted)
                    }
                    StorageCard(label: "Disk free", value: storage.diskText)
                }
            }
            section(.class("page-section")) {
                div(.class("page-titlebar")) {
                    h2 {
                        "By Assignment "
                        span(.class("text-muted")) { "Largest first" }
                    }
                }
                if assignmentRows.isEmpty {
                    p(.class("text-muted")) { "No assignments yet." }
                } else {
                    // The bar is the row's size against the largest row; the
                    // label is its share of the total on disk.
                    table(.class("results-table section-items section-items--manage")) {
                        colgroup {
                            col(.class("section-items-tile"))
                            col()
                            col(.class("section-items-seen col-hide-phone"))
                            col(.class("section-items-count"))
                        }
                        thead(.class("visually-hidden")) {
                            tr {
                                for heading in ["Assignment", "Detail", "Share of total", "Total"] {
                                    th(.custom(name: "scope", value: "col")) { heading }
                                }
                            }
                        }
                        tbody {
                            for row in assignmentRows {
                                StorageAssignmentRow(row: row)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One storage figure as a diagnostic card.
private struct StorageCard: HTML {
    let label: String
    let value: String

    var body: some HTML {
        div(.class("diagnostic-card")) {
            div(.class("diagnostic-label")) { label }
            div(.class("diagnostic-value")) { value }
        }
    }
}

/// One assignment's footprint, with its share bar.
private struct StorageAssignmentRow: HTML {
    let row: AdminStorageShareRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-list") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) { row.assignmentTitle }
                div(.class("item-details")) {
                    span(.class("content-item-kind"), .data("kind", value: "graded")) { row.courseCode }
                    " · \(row.detailsText)"
                }
            }
            td(.class("col-hide-phone")) {
                // A custom-property assignment, the one inline style the UI rules allow.
                span(.class("share-bar"), .custom(name: "style", value: "--share:\(row.barPercent)%")) {}
                div(.class("item-details item-grade")) { row.shareLabel }
            }
            td(.class("item-status item-grade")) { strong { row.totalFormatted } }
        }
    }
}

// APIServer/Views/WorkerRows.swift
//
// The rows of the admin Overview's runners table. `AdminPage` renders them in
// the table, and `GET /admin/runners?fragment=rows` renders them alone for
// `table-poll.js`. Both render this one struct, so the poll cannot drift from
// the page.

import Elementary

struct WorkerRows: HTML {
    let workers: [AdminRunnerRow]

    var body: some HTML {
        for worker in workers {
            WorkerRow(worker: worker)
        }
    }
}

/// One runner: its id and details, its load, and when it was last active.
struct WorkerRow: HTML {
    let worker: AdminRunnerRow

    var body: some HTML {
        tr(
            .data("load", value: String(worker.assignedJobs)),
            .data("max-jobs", value: String(worker.maxConcurrentJobs))
        ) {
            td(.class("item-tile-cell")) {
                span(.class("item-tile")) { Icon("i-server") }
            }
            td(.class("item-main"), .data("sort-value", value: worker.workerID)) {
                div(.class("item-title")) {
                    a(.href("/admin/runners/\(worker.workerID)")) { code { worker.workerID } }
                }
                div(.class("item-details")) { worker.detailsText }
            }
            td(.class("item-status"), .data("sort-value", value: String(worker.assignedJobs))) {
                if worker.isOffline {
                    span(.class("tier")) { "Offline" }
                } else if worker.hasSlots {
                    span(.class("pips"), .ariaHidden) {
                        for pip in worker.pips {
                            span(.class("pip"), .data("state", value: pip.state)) {}
                        }
                    }
                    div(.class("item-details")) { worker.loadLabel }
                } else {
                    worker.loadLabel
                }
            }
            td(.class("col-hide-phone"), .data("iso", value: worker.lastActive)) {
                span(.class("js-relative-time"), .data("iso", value: worker.lastActive)) { worker.lastActive }
                div(.class("item-details")) { "last active" }
            }
            td(.class("item-actions-td")) {
                a(
                    .class("btn action-btn action-btn-icon"), .href("/admin/runners/\(worker.workerID)"),
                    .title("Open runner"), .ariaLabel("Open runner \(worker.workerID)")
                ) {
                    Icon("i-eye")
                }
            }
        }
        .attributes(.class("row-muted"), when: worker.isOffline)
    }
}

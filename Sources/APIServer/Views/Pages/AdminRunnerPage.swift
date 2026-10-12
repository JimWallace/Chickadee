// APIServer/Views/Pages/AdminRunnerPage.swift
//
// GET /admin/runners/:runnerID: one runner's detail page. Detail-page shape,
// shared with the course and user pages: titlebar (name, current state) →
// subtitle (the identifiers you would paste into a ticket) → a status block
// ONLY when something is wrong → the facts → the history (a utilization chart,
// then recent jobs). The offline badge and the 5s live-status poll are wired
// by Public/admin-runner.js.

import Elementary

struct AdminRunnerPage: HTML {
    let page: PageRequestContext
    let runner: AdminWorkerRow
    let tags: [String]
    let summary: AdminRunnerSummary
    let recentJobs: [AdminRunnerJobRow]
    let snapshots: [AdminRunnerSnapshotRow]
    let firstSeenAt: String?
    /// The snapshots oldest to newest, one bar each.
    let chartBars: [AdminRunnerChartBar]
    /// Three or four evenly spaced clock times for the chart's x-axis.
    let chartLabels: [String]
    /// "12m 3s" since the last heartbeat; empty while the runner is online.
    let offlineForText: String

    var body: some HTML {
        BaseLayout(title: "Runner \(runner.workerID)", page: page) {
            AvatarSprite(page: page)
            section(.class("page-section")) {
                p(.class("page-crumb")) {
                    a(.href("/admin")) { "Overview" }
                    " › Runners"
                }
                div(.data("runner-id", value: runner.workerID), .class("page-titlebar")) {
                    h1 {
                        code { runner.workerID }
                        " "
                        span(.id("runner-offline-badge"), .class("tier")) { "Offline" }
                            .attributes(.hidden, when: !runner.isOffline)
                    }
                }
                subtitle
                FlashBanner(.warning) {
                    strong { offlineForText.isEmpty ? "No heartbeat." : "No heartbeat for \(offlineForText)." }
                    " Chickadee has stopped handing this runner work; queued jobs wait for a runner that is online."
                }
                .attributes(.id("runner-offline-status"))
                .attributes(.hidden, when: !runner.isOffline)
                statusCards
                div(.class("card section-gap")) {
                    RunnerFacts(runner: runner, summary: summary, tags: tags)
                }
            }
            utilization
            section(.class("page-section")) {
                h2 { "Recent Jobs" }
                if recentJobs.isEmpty {
                    p(.class("empty")) { "No recorded jobs for this runner yet." }
                } else {
                    jobsTable
                }
            }
            script(.src(page.asset("/admin-runner.js"))) {}
            script(.src(page.asset("/sortable-table.js"))) {}
        }
    }

    /// Host, version and first registration.
    private var subtitle: some HTML {
        p(.class("section-intro")) {
            span(.id("runner-hostname")) { runner.hostname.isEmpty ? "Unknown host" : runner.hostname }
            " · "
            span(.id("runner-version")) { runner.runnerVersion.isEmpty ? "Unknown version" : runner.runnerVersion }
            if let firstSeenAt {
                " · registered "
                span(.class("js-relative-time"), .data("iso", value: firstSeenAt)) { firstSeenAt }
            }
        }
    }

    private var statusCards: some HTML {
        div(.class("diagnostics-cards section-gap")) {
            StatusCard(label: "Passed", value: summary.passedCount)
            StatusCard(label: "Failed", value: summary.failedCount)
            StatusCard(label: "Errored", value: summary.errorCount)
            StatusCard(label: "Timed Out", value: summary.timeoutCount)
        }
    }

    private var utilization: some HTML {
        section(.class("page-section")) {
            h2 { "Utilization" }
            if chartBars.isEmpty {
                p(.class("empty")) { "No heartbeat or poll snapshots recorded yet." }
            } else {
                // Bars are server-rendered; each height is a percent passed as
                // a custom property. The same numbers sit in the visually
                // hidden table below.
                div(.class("spark-chart")) {
                    div(.class("spark-chart-scale"), .ariaHidden) {
                        span { "100" }
                        span { "50" }
                        span { "0" }
                    }
                    div(.class("diagnostic-spark"), .ariaHidden) {
                        for bar in chartBars {
                            div(.class("spark-slot"), .title(bar.title)) {
                                // A custom property, the one inline style the UI rules allow.
                                span(
                                    .class("spark-fill"), .data("state", value: bar.state),
                                    .custom(name: "style", value: "--bar-h:\(bar.heightPercent)%")
                                ) {}
                            }
                        }
                    }
                    div(.class("spark-chart-axis"), .ariaHidden) {
                        for label in chartLabels {
                            span { label }
                        }
                    }
                }
                if runner.isOffline {
                    p(.class("section-note")) { "None since it went offline." }
                }
                div(.class("visually-hidden")) {
                    SnapshotTable(snapshots: snapshots)
                }
            }
        }
    }

    private var jobsTable: some HTML {
        table(.class("results-table section-items section-items--manage sortable-table")) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-seen col-hide-phone"))
                col(.class("section-items-count"))
            }
            thead {
                tr {
                    th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Person" } }
                    th(.data("sort-type", value: "text")) {
                        button(.class("sort-header"), .type(.button)) { "User" }
                    }
                    th(.data("sort-type", value: "text")) {
                        button(.class("sort-header"), .type(.button)) { "Status" }
                    }
                    th(.class("col-hide-phone"), .data("sort-type", value: "date")) {
                        button(.class("sort-header"), .type(.button)) { "Completed" }
                    }
                    th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Open" } }
                }
            }
            tbody {
                for job in recentJobs {
                    RunnerJobRow(job: job)
                }
            }
        }
    }
}

/// One count in the row of status cards.
private struct StatusCard: HTML {
    let label: String
    let value: Int

    var body: some HTML {
        div(.class("diagnostic-card")) {
            span(.class("diagnostic-label")) { label }
            span(.class("diagnostic-value")) { String(value) }
        }
    }
}

/// The facts grid: activity, capacity, the stage timings a runner reported,
/// and its capability tags.
private struct RunnerFacts: HTML {
    let runner: AdminWorkerRow
    let summary: AdminRunnerSummary
    let tags: [String]

    var body: some HTML {
        dl(.class("detail-grid detail-grid--cells")) {
            div {
                dt { "Last active" }
                dd {
                    span(
                        .id("runner-last-active"), .class("js-relative-time"),
                        .data("iso", value: runner.lastActive)
                    ) { runner.lastActive }
                }
            }
            Fact(label: "Capacity", value: "\(summary.activeJobs) / \(summary.maxJobs) jobs")
            Fact(label: "Jobs processed", value: String(summary.jobsProcessed))
            if let value = summary.avgQueueWaitFormatted { Fact(label: "Avg wait", value: value) }
            if let value = summary.avgDownloadFormatted { Fact(label: "Avg download", value: value) }
            if let value = summary.avgPrepFormatted { Fact(label: "Avg prep", value: value) }
            if let value = summary.avgExecutionFormatted { Fact(label: "Avg run", value: value) }
            if let value = summary.avgCacheAcquireFormatted { Fact(label: "Avg cache acquire", value: value) }
            if let value = summary.cacheHitRateFormatted { Fact(label: "Cache hit rate", value: value) }
            if let value = summary.avgOverheadFormatted { Fact(label: "Avg setup/other", value: value) }
            if !tags.isEmpty {
                div {
                    dt { "Tags" }
                    dd {
                        div(.class("chip-row")) {
                            for tag in tags {
                                " "
                                span(.class("chip")) { tag }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One cell of the facts grid.
private struct Fact: HTML {
    let label: String
    let value: String

    var body: some HTML {
        div {
            dt { label }
            dd { value }
        }
    }
}

/// The chart's numbers as a table, for a screen reader.
private struct SnapshotTable: HTML {
    let snapshots: [AdminRunnerSnapshotRow]

    var body: some HTML {
        table(.class("results-table")) {
            caption { "Recent snapshots" }
            thead {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Recorded" }
                    th(.custom(name: "scope", value: "col")) { "Active Jobs" }
                    th(.custom(name: "scope", value: "col")) { "Utilization %" }
                    th(.custom(name: "scope", value: "col")) { "Last Poll" }
                }
            }
            tbody {
                for snapshot in snapshots {
                    tr {
                        td { snapshot.recordedAt }
                        td { snapshot.activeJobsLabel }
                        td { "\(snapshot.utilizationPercent)%" }
                        td { snapshot.lastPollAt ?? "—" }
                    }
                }
            }
        }
    }
}

/// One recent job: who submitted, how it ended, when, and a link to it.
private struct RunnerJobRow: HTML {
    let job: AdminRunnerJobRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                if job.hasAvatar, let avatar = job.avatar {
                    Avatar(avatar: avatar)
                } else {
                    span(.class("item-tile")) { Icon("i-cpu") }
                }
            }
            td(.class("item-main"), .data("sort-value", value: job.username ?? "~")) {
                if let username = job.username {
                    div(.class("item-title")) { username }
                } else {
                    div(.class("item-title text-muted")) { "No user" }
                }
                div(.class("item-details")) {
                    if !job.detailsText.isEmpty {
                        "\(job.detailsText) · "
                    }
                    code { job.submissionID }
                }
            }
            td(.class("item-status"), .data("sort-value", value: job.finalStatus)) {
                span(.class("tier tier-\(job.statusTier)")) { job.statusLabel }
                if !job.limitText.isEmpty {
                    div(.class("item-details item-details--danger")) { job.limitText }
                }
            }
            if let completedAt = job.completedAt {
                td(
                    .class("col-hide-phone js-relative-time"), .data("iso", value: completedAt),
                    .data("sort-value", value: completedAt)
                ) { completedAt }
            } else {
                td(.class("col-hide-phone js-relative-time"), .data("sort-value", value: "")) { "—" }
            }
            td(.class("item-actions-td")) {
                a(
                    .class("btn action-btn action-btn-icon"), .href("/submissions/\(job.submissionID)"),
                    .title("Open submission"), .ariaLabel("Open submission \(job.submissionID)")
                ) {
                    " "
                    Icon("i-eye")
                    " "
                }
            }
        }
    }
}

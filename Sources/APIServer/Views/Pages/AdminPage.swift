// APIServer/Views/Pages/AdminPage.swift
//
// GET /admin: the admin Overview. Diagnostic cards, the runners table (polled
// through `WorkerRows`) and the active courses. Public/admin-dashboard.js
// wires the cards, the Active Users card and the import-course picker.

import Elementary

struct AdminPage: HTML {
    let page: PageRequestContext
    let workers: [AdminRunnerRow]
    let courses: [AdminCourseRow]
    /// The default (24h) activity series, drawn before the first poll.
    let activityChart: ActivityChartData

    /// Whether the course list is long enough to earn a filter box.
    private var showCourseFilter: Bool {
        ListFilterPolicy.showsFilter(rowCount: courses.count)
    }

    var body: some HTML {
        BaseLayout(title: "Admin", page: page) {
            AdminTabs(active: .overview, page: page)
            diagnosticsSection
            runnersSection
            coursesSection
            script(.src(page.asset("/sortable-table.js"))) {}
            script(.src(page.asset("/list-filter.js"))) {}
            script(.src(page.asset("/table-poll.js"))) {}
            script(.src(page.asset("/admin-dashboard.js"))) {}
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some HTML {
        section(.class("diagnostics-section")) {
            div(.class("diagnostics-cards"), .id("diagnostics-cards")) {
                div(
                    .class("diagnostic-card diagnostic-card-cyclable"), .dataFlag("activity-card"),
                    .role("button"), .tabindex(0),
                    .ariaLabel("Active users, last 24 hours. Press to change the time window.")
                ) {
                    div(.class("diagnostic-label")) {
                        span(.class("diagnostic-window-chip"), .id("activity-card-window")) { "24h" }
                        " Active Users"
                    }
                    div(.class("diagnostic-value"), .id("activity-card-value")) { "—" }
                    div(.class("diagnostic-spark"), .id("activity-card-spark"), .ariaHidden) {
                        for bucket in activityChart.buckets {
                            div(
                                .class("spark-slot"), .data("count", value: String(bucket.count)),
                                .data("label", value: bucket.label)
                            ) {
                                span(.class("spark-fill")) {}
                            }
                        }
                    }
                }
                MetricsDiagnosticCard(
                    hook: .admin, key: "jobsProcessed", label: "Jobs Processed", spoken: "Jobs processed",
                    valueID: "diag-jobs-processed")
                MetricsDiagnosticCard(
                    hook: .admin, key: "load", label: "Max Load", spoken: "Max load", valueID: "diag-max-load")
                MetricsDiagnosticCard(
                    hook: .admin, key: "queueWaitP95Ms", label: "P95 Wait Time", spoken: "P95 wait time",
                    valueID: "diag-queue-p95")
            }
        }
    }

    // MARK: - Runners

    private var runnersSection: some HTML {
        section(.class("page-section")) {
            h2 { "Runners" }
            table(
                .id("workers-table"), .class("results-table section-items section-items--manage sortable-table"),
                .data("sort-initial", value: "runner:asc"), .data("sort-tiebreak", value: "runner"),
                .data("poll-url", value: "/admin/runners?fragment=rows"), .data("poll-interval", value: "5000")
            ) {
                colgroup {
                    col(.class("section-items-tile"))
                    col()
                    col(.class("section-items-status"))
                    col(.class("section-items-seen col-hide-phone"))
                    col(.class("section-items-count"))
                }
                thead {
                    tr {
                        th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Runner" } }
                        SortHeader(key: "runner", type: "text", label: "Runner")
                        SortHeader(key: "load", type: "number", label: "Load")
                        SortHeader(key: "last-active", type: "date", label: "Last active", hideOnPhone: true)
                        th(.custom(name: "scope", value: "col")) { span(.class("visually-hidden")) { "Open" } }
                    }
                }
                tbody(.id("workers-body")) {
                    WorkerRows(workers: workers)
                }
            }
        }
    }

    // MARK: - Courses

    private var coursesSection: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "Courses "
                    span(.class("text-muted")) { "\(courses.count) active" }
                }
                addMenu
            }
            // The hidden import form, submitted by the menu item above.
            form(
                .method(.post), .action("/admin/courses/import"), .enctype(.multipartFormData),
                .id("importCourseForm")
            ) {
                CSRFField(token: page.csrfToken)
                input(
                    .type(.file), .name("file"), .custom(name: "accept", value: ".zip"), .id("importCourseFile"),
                    .hidden)
            }
            if courses.isEmpty {
                p(.class("empty")) { "No courses yet." }
            } else {
                if showCourseFilter {
                    courseFilter
                }
                coursesTable
            }
        }
    }

    private var addMenu: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "+ Add "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                a(.class("row-menu-item"), .href("/admin/courses/new"), .role("menuitem")) {
                    span(.class("item-tile"), .data("kind", value: "notebook")) { Icon("i-plus") }
                    span {
                        "Create course"
                        br()
                        span(.class("card-meta")) { "A new offering in a term" }
                    }
                }
                button(.class("row-menu-item"), .type(.button), .id("importCourseBtn"), .role("menuitem")) {
                    span(.class("item-tile"), .data("kind", value: "document")) { Icon("i-upload") }
                    span {
                        "Import course bundle"
                        br()
                        span(.class("card-meta")) { "From a .zip exported here" }
                    }
                }
            }
        }
    }

    private var courseFilter: some HTML {
        div(.class("toolbar toolbar--end section-gap")) {
            span(.class("filter-group")) {
                label(.class("filter-label"), .for("courses-filter")) { "Filter" }
                input(
                    .id("courses-filter"), .class("form-input filter-input"), .type(.search),
                    .placeholder("Filter by code or name…"), .data("list-filter", value: "courses-table"),
                    .data("list-filter-empty", value: "No courses match this filter."))
            }
        }
    }

    private var coursesTable: some HTML {
        table(.class("results-table section-items section-items--manage"), .id("courses-table")) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-count"))
                col(.class("section-items-count"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Course" }
                    th(.custom(name: "scope", value: "col")) { "Name" }
                    th(.custom(name: "scope", value: "col")) { "Students" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            tbody {
                for course in courses {
                    AdminCourseTableRow(course: course, csrfToken: page.csrfToken)
                }
            }
        }
    }
}

/// One active course, with its clone link and its export and archive menu.
private struct AdminCourseTableRow: HTML {
    let course: AdminCourseRow
    let csrfToken: String

    private var detailsText: String {
        let submissions = "\(course.submissionCount) submissions"
        guard let term = course.termLabel, !term.isEmpty else { return submissions }
        return "\(term) · \(submissions)"
    }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "notebook")) { Icon("i-layers") }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    a(.href("/admin/courses/\(course.id)")) { "\(course.code) — \(course.name)" }
                }
                div(.class("item-details")) { detailsText }
            }
            td(.class("item-status item-grade")) {
                strong { String(course.enrollmentCount) }
                div(.class("item-details")) { "students" }
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    a(
                        .class("btn action-btn action-btn-icon"), .href("/admin/courses/\(course.id)#clone-course"),
                        .title("Clone course"), .ariaLabel("Clone course")
                    ) {
                        Icon("i-copy")
                    }
                    rowMenu
                }
            }
        }
    }

    private var rowMenu: some HTML {
        RowMenu(for: course.code) {
            a(.class("row-menu-item"), .href("/admin/courses/\(course.id)/export"), .role("menuitem")) {
                Icon("i-download")
                "Export course bundle"
            }
            form(
                .method(.post), .action("/admin/courses/\(course.id)/archive"),
                .data(
                    "confirm",
                    value:
                        "Archive \(course.code)? \(course.enrollmentCount) students lose access immediately. Submissions, grades and audit records are kept, and Unarchive on the course page puts it back."
                )
            ) {
                CSRFField(token: csrfToken)
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-archive")
                    "Archive course"
                }
            }
        }
    }
}

// APIServer/Views/Pages/InstructorActivityPage.swift
//
// GET /instructor/activity: the Activity tab. The active course's content
// edits and course events under day headings, newest first, filtered by
// person.

import Elementary

struct InstructorActivityPage: HTML {
    let page: PageRequestContext
    let hasActiveCourse: Bool
    /// The rows grouped under Today / Yesterday / date headings.
    let days: [ActivityDay]
    /// The person select: "Everyone" first, then course staff by name.
    let staffOptions: [ActivityStaffOption]
    let hasRows: Bool
    /// True when a person filter is applied.
    let filtered: Bool

    var body: some HTML {
        BaseLayout(title: "Activity", page: page) {
            InstructorTabs(active: .activity)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to see its activity." }
                }
            } else {
                div(.class("page-titlebar")) {
                    h2 { "Recent activity" }
                    form(.method(.get), .action("/instructor/activity"), .class("form-flush")) {
                        label(.class("visually-hidden"), .for("activity-actor")) { "Person" }
                        select(
                            .id("activity-actor"), .name("actor"), .class("form-input"),
                            .dataFlag("ck-submit-on-change")
                        ) {
                            for option in staffOptions {
                                Elementary.option(.value(option.username)) { option.displayName }
                                    .attributes(.selected, when: option.selected)
                            }
                        }
                        noscript { button(.type(.submit), .class("btn action-btn")) { "Show" } }
                    }
                }
                p(.class("section-intro")) {
                    "Content edits and course events for this course, newest first. "
                    "Every content edit is a recoverable version of the assignment it names."
                }
                if hasRows {
                    activityTable
                } else {
                    p(.class("empty")) {
                        filtered ? "No activity matches that person." : "No recorded activity for this course yet."
                    }
                }
            }
            PageStyle(
                """
                .activity-detail {
                    font-family: var(--font-mono);
                    word-break: break-word;
                }
                """
            )
        }
    }

    private var activityTable: some HTML {
        table(.class("results-table section-items section-items--manage")) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-seen col-hide-phone"))
                col(.class("section-items-count"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Type" }
                    th(.custom(name: "scope", value: "col")) { "What happened" }
                    th(.custom(name: "scope", value: "col"), .class("col-hide-phone")) { "When" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            tbody {
                for day in days {
                    tr(.class("section-items-heading")) {
                        td(.custom(name: "colspan", value: "4")) { strong { day.label } }
                    }
                    for row in day.rows {
                        ActivityEventRow(row: row)
                    }
                }
            }
        }
    }
}

/// One event: who did what to what, and when.
private struct ActivityEventRow: HTML {
    let row: CourseTimelineRow

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: row.tileKind)) {
                    SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(row.iconHref)) {} }
                }
            }
            td(.class("item-main")) {
                div(.class("item-title")) {
                    strong { row.actor }
                    " \(row.summary) "
                    if let link = row.link {
                        a(.href(link)) { row.target }
                    } else {
                        row.target
                    }
                }
                div(.class("item-details")) {
                    "\(row.category) · \(row.clockText)"
                    if !row.detail.isEmpty {
                        " · "
                        span(.class("activity-detail")) { row.detail }
                    }
                }
            }
            td(.class("col-hide-phone js-relative-time"), .data("iso", value: row.timestampISO)) { row.timestamp }
            td(.class("item-actions-td")) {
                if let link = row.link {
                    div(.class("assignment-actions-cell")) {
                        a(
                            .class("btn action-btn action-btn-icon"), .href(link), .title("View \(row.target)"),
                            .ariaLabel("View \(row.target)")
                        ) { Icon("i-eye") }
                    }
                }
            }
        }
    }
}

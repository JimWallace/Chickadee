// APIServer/Views/Pages/IndexPage.swift
//
// GET /: the student dashboard. The active course's assignments and course
// materials, one table per course section, with the per-row grade and the
// student's actions (edit, upload, reset, slip day, solution, leaderboard).

import Elementary

struct IndexPage: HTML {
    let page: PageRequestContext
    /// The course the viewer is looking at; nil when they are enrolled in none.
    let activeCourse: CourseContext?
    /// Named sections first, then the ungrouped bucket.
    let displayGroups: [IndexDisplayGroup]
    /// True when any group has a visible item.
    let hasAny: Bool
    /// "Slip days: 1 of 2 remaining." under the heading; nil hides the line.
    let slipDaySummary: String?

    private var heading: String {
        if let activeCourse { "\(activeCourse.code) — \(activeCourse.name)" } else { "Assignments" }
    }

    var body: some HTML {
        BaseLayout(title: heading, page: page) {
            h1 { heading }
            if let slipDaySummary {
                div(.class("chip-row")) {
                    span(.class("chip")) { slipDaySummary }
                }
            }
            if !hasAny {
                if activeCourse != nil {
                    div(.class("notice-box")) {
                        p(.class("empty")) { "No assignments available yet." }
                        p(.class("section-note")) { "Labs open one at a time as the term goes on." }
                        p { a(.href("/account")) { "Check your course memberships" } }
                    }
                } else {
                    p(.class("empty")) {
                        "You are not enrolled in any courses. "
                        a(.href("/account")) { "Go to My Account" }
                        " to see your course memberships."
                    }
                }
            } else {
                for (index, group) in displayGroups.enumerated() {
                    IndexSectionTable(page: page, group: group, index: index)
                }
            }
            script(.src(page.asset("/list-filter.js"))) {}
        }
    }
}

/// One course section: its heading, its Filter box, and its table.
private struct IndexSectionTable: HTML {
    let page: PageRequestContext
    let group: IndexDisplayGroup
    /// The group's position on the page, which keys the table and its filter.
    let index: Int

    var body: some HTML {
        if let name = group.name {
            h2(.class("assignment-section-heading")) { name }
        }
        if group.showFilter {
            div(.class("toolbar toolbar--end section-gap")) {
                span(.class("filter-group")) {
                    " "
                    label(.class("filter-label"), .for("filter-assignments-\(index)")) { "Filter" }
                    " "
                    input(
                        .id("filter-assignments-\(index)"), .class("form-input filter-input"), .type(.search),
                        .placeholder("Filter this section…"), .data("list-filter", value: "assignments-\(index)"),
                        .data("list-filter-empty", value: "No items in this section match."))
                    " "
                }
            }
        }
        table(.class("results-table section-items"), .id("assignments-\(index)")) {
            colgroup {
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-grade col-hide-phone"))
                col(.class("section-items-actions"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Type" }
                    th(.custom(name: "scope", value: "col"), .data("sort-key", value: "name")) { "Name" }
                    th(.custom(name: "scope", value: "col"), .data("sort-key", value: "status")) { "Status" }
                    th(.custom(name: "scope", value: "col"), .class("col-hide-phone")) { "Grade" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            tbody {
                for item in group.items {
                    if item.isContent, let content = item.content {
                        IndexContentRow(content: content)
                    } else if !item.isContent, let row = item.row {
                        IndexAssignmentRow(page: page, row: row)
                    }
                }
            }
        }
    }
}

/// A piece of course material, or a heading.
private struct IndexContentRow: HTML {
    let content: ContentItemRow

    var body: some HTML {
        if content.isHeading {
            tr(.class("section-items-heading")) {
                td(.custom(name: "colspan", value: "5")) {
                    strong { content.title }
                    if let description = content.itemDescription {
                        " "
                        span(.class("text-muted")) { description }
                    }
                }
            }
        } else {
            tr {
                td(.class("item-tile-cell")) {
                    span(.class("item-tile"), .data("kind", value: content.kind)) {
                        SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(content.iconHref)) {} }
                    }
                }
                td(.class("item-main")) {
                    div(.class("item-title")) {
                        content.title
                        if !content.isPublished {
                            " "
                            span(.class("content-item-hidden")) { "Hidden" }
                        }
                    }
                    div(.class("item-details")) {
                        span(.class("content-item-kind"), .data("kind", value: content.kind)) { content.kindLabel }
                        if !content.detailsText.isEmpty { " · \(content.detailsText)" }
                    }
                }
                td(.class("item-status")) {}
                td(.class("col-hide-phone")) {}
                td(.class("item-actions-td")) {
                    div(.class("assignment-actions-cell")) {
                        for (position, action) in content.actions.enumerated() {
                            if position > 0 { " " }
                            a(
                                .class("btn action-btn action-btn-icon"), .href(action.href), .title(action.label),
                                .ariaLabel(action.label)
                            ) {
                                " "
                                SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(action.iconHref)) {} }
                                " "
                            }
                            .attributes(.target(.blank), .rel("noopener noreferrer"), when: action.opensNewTab)
                        }
                    }
                }
            }
        }
    }
}

/// A graded assignment.
private struct IndexAssignmentRow: HTML {
    let page: PageRequestContext
    let row: TestSetupRow

    private var statusClass: String {
        switch row.status {
        case "open": "tier tier-open"
        case "closed": "tier tier-closed"
        case "unpublished": "tier tier-unpublished"
        default: "tier"
        }
    }

    var body: some HTML {
        tr {
            td(.class("item-tile-cell")) {
                span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-calendar-check") }
            }
            td(.class("item-main")) { mainCell }
            td(.class("item-status")) {
                if row.staffOnly {
                    span(
                        .class("tier tier-preview staff-only-tag"),
                        .title("Visible to course staff only — students can't see this assignment yet.")
                    ) { "preview" }
                } else if row.status == "extended" {
                    span(.class("tier tier-extended"), .title("You can submit past the class deadline")) {
                        "extended"
                    }
                } else {
                    span(.class(statusClass)) { row.status }
                }
            }
            td(.class("item-grade col-hide-phone")) {
                if let grade = row.latest.bestGradeText {
                    strong { grade }
                } else {
                    span(.class("empty")) { "—" }
                }
            }
            td(.class("item-actions-td")) {
                IndexAssignmentActions(page: page, row: row)
            }
        }
    }

    @HTMLBuilder private var mainCell: some HTML {
        if let title = row.title {
            div(.class("assignment-title-cell")) {
                strong { title }
                if !row.badges.isEmpty {
                    " "
                    // Leaf wrote each badge on its own line, so a space
                    // pads every badge, the first and last included.
                    span(.class("achievement-badges achievement-badges-compact")) {
                        for badge in row.badges {
                            " "
                            span(.class("achievement-badge achievement-badge-compact"), .title(badge.tooltip)) {
                                badge.label
                            }
                        }
                        if row.extraBadgeCount > 0 {
                            " "
                            span(
                                .class("achievement-badge achievement-badge-compact achievement-badge-overflow"),
                                .title("Also earned: \(row.extraBadgesTooltip ?? "")")
                            ) { "+\(row.extraBadgeCount)" }
                        }
                        " "
                    }
                }
            }
            div(.class("item-details")) {
                dueLine
                if row.latest.submissionCount == 1 {
                    " · "
                    a(.href(row.historyURL)) { "1 submission" }
                } else if row.latest.submissionCount > 1 {
                    " · "
                    a(.href(row.historyURL)) { "\(row.latest.submissionCount) submissions" }
                }
                if row.latest.gradeIsOverridden {
                    " · "
                    span(.class("grade-override-tag"), .title("Your grade was set by your instructor")) { "adjusted" }
                }
                if let grade = row.latest.bestGradeText {
                    " "
                    span(.class("row-phone-meta")) { "Grade \(grade)" }
                }
            }
        } else {
            span(.class("text-muted")) { "Unpublished" }
        }
    }

    @HTMLBuilder private var dueLine: some HTML {
        if let opensAtText = row.opensAtText {
            span(.title("This assignment opens automatically at this time.")) { "Opens \(opensAtText)" }
        } else if row.hasActiveExtension {
            let effective = row.effectiveDueAtText ?? ""
            "Due "
            span(.class("js-relative-time"), .data("iso", value: row.effectiveDueAtISO ?? "")) { effective }
            " · \(effective) "
            span(.class("card-meta")) { "(extension)" }
        } else if let dueAt = row.dueAt {
            "Due "
            span(.class("js-relative-time"), .data("iso", value: row.dueAtISO ?? "")) { dueAt }
            " · \(dueAt)"
        } else {
            "No due date"
        }
    }
}

/// The Actions cell of an assignment row. Leaf wrote each button on its own
/// line, so a space separates neighbouring buttons and pads each icon.
private struct IndexAssignmentActions: HTML {
    let page: PageRequestContext
    let row: TestSetupRow

    var body: some HTML {
        div(.class("assignment-actions-cell")) {
            if !row.hasAnyAction {
                span(.class("empty")) { "—" }
            }
            if row.showEditAction {
                " "
                IndexIconLink(href: row.notebookURL, label: "Edit", icon: "i-pencil")
            }
            if row.showUploadAction {
                " "
                IndexIconLink(href: row.submitURL, label: "Upload", icon: "i-upload")
            }
            if row.showResetNotebookAction {
                form(
                    .method(.post), .action("/testsetups/\(row.id)/reset-notebook"),
                    .data(
                        "confirm",
                        value:
                            "Reset your notebook back to the original starter? This discards your current edits for this assignment. Your past submissions are not affected."
                    ), .class("inline-form")
                ) {
                    CSRFField(token: page.csrfToken)
                    " "
                    button(
                        .class("btn action-btn action-btn-icon action-danger"), .type(.submit),
                        .title("Reset notebook to starter (discards current edits; past submissions unaffected)"),
                        .ariaLabel("Reset notebook to starter")
                    ) {
                        " "
                        Icon("i-rewind")
                        " "
                    }
                }
            }
            if row.slipDayAvailable {
                " "
                IndexIconLink(href: row.slipDayURL, label: row.slipDayActionLabel, icon: "i-calendar")
            }
            if row.solutionAvailable {
                " "
                IndexIconLink(href: row.solutionURL, label: "Solution", icon: "i-key")
            }
            if let leaderboardURL = row.leaderboardURL {
                " "
                IndexIconLink(href: leaderboardURL, label: "Leaderboard", icon: "i-award")
            }
        }
    }
}

/// One icon button that is a link.
private struct IndexIconLink: HTML {
    let href: String
    let label: String
    let icon: String

    var body: some HTML {
        a(.class("btn action-btn action-btn-icon"), .href(href), .title(label), .ariaLabel(label)) {
            " "
            Icon(icon)
            " "
        }
    }
}

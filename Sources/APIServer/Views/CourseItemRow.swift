// APIServer/Views/CourseItemRow.swift
//
// One row of the instructor Overview item list (`AssignmentsPage`): a graded
// assignment, an unpublished setup, a piece of ungraded material, or a
// heading. Every row is a tile, a name with one details line, a state track,
// a submitted count and an actions track; the drag handle sits in its own
// leading cell.
//
// The sections table and the ungrouped table render the same row. They were
// two copies once, and the copies drifted: the ungrouped one lost the retest
// action and the copy-student-link action, so an assignment outside a section
// rendered without them. Keep one row.

import Core
import Elementary

struct CourseItemRow: HTML {
    let item: InstructorSectionItem
    /// The course's enrolled students, for the "X / Y submitted" count.
    let enrolledStudentCount: Int
    let csrfToken: String
    /// The instructor-only controls the viewer gets. Material rows need none.
    let controls: DashboardControls

    var body: some HTML {
        if item.isContent, let content = item.content {
            CourseContentItemRow(content: content, csrfToken: csrfToken)
        } else if let row = item.row {
            CourseAssignmentItemRow(
                row: row, enrolledStudentCount: enrolledStudentCount, csrfToken: csrfToken, controls: controls)
        }
    }
}

/// A piece of ungraded material, or a heading.
private struct CourseContentItemRow: HTML {
    let content: ContentItemRow
    let csrfToken: String

    private static let kinds: [(value: String, label: String)] = [
        ("link", "Link"), ("notebook", "Notebook"), ("document", "Document"), ("slides", "Slides"),
        ("outline", "Outline"), ("heading", "Heading"),
    ]

    var body: some HTML {
        tr(.data("content-item-id", value: content.id)) {
            td(.class("section-items-handle")) { span(.class("suite-drag-handle"), .ariaHidden) { "⋮⋮" } }
            if content.isHeading {
                td(.custom(name: "colspan", value: "4")) {
                    strong { content.title }
                    if let description = content.itemDescription {
                        " "
                        span(.class("text-muted")) { description }
                    }
                }
            } else {
                td(.class("item-tile-cell")) {
                    span(.class("item-tile"), .data("kind", value: content.kind)) {
                        SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(content.iconHref)) {} }
                    }
                }
                td(.class("item-main")) {
                    div(.class(content.isPublished ? "item-title" : "item-title text-muted")) { content.title }
                    div(.class("item-details")) {
                        span(.class("content-item-kind"), .data("kind", value: content.kind)) { content.kindLabel }
                        if !content.detailsText.isEmpty { " · \(content.detailsText)" }
                    }
                }
                td(.class("item-status")) { visibilityForm }
                td(.class("col-hide-phone")) {}
            }
            td(.class("item-actions-td")) {
                div(.class("assignment-actions-cell")) {
                    for action in content.actions {
                        a(
                            .class("btn action-btn action-btn-icon"), .href(action.href), .title(action.label),
                            .ariaLabel(action.label)
                        ) {
                            SVG.svg(.class("icon"), .ariaHidden) { SVG.use(.href(action.iconHref)) {} }
                        }
                        .attributes(.target(.blank), .rel("noopener noreferrer"), when: action.opensNewTab)
                    }
                    editPopover
                    RowMenu(for: content.title) {
                        form(
                            .method(.post), .action("/instructor/content-items/\(content.id)/delete"),
                            .data("confirm", value: "Delete this material?")
                        ) {
                            CSRFField(token: csrfToken)
                            button(
                                .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")
                            ) {
                                Icon("i-trash")
                                "Delete material"
                            }
                        }
                    }
                }
            }
        }
        .attributes(.class("section-items-heading"), when: content.isHeading)
    }

    private var visibilityForm: some HTML {
        form(
            .method(.post), .action("/instructor/content-items/\(content.id)/visibility"), .class("status-form")
        ) {
            CSRFField(token: csrfToken)
            label(.class("visually-hidden"), .for("visibility-\(content.id)")) { "Visibility of \(content.title)" }
            span(.class("state-select"), .data("state", value: content.isPublished ? "visible" : "hidden")) {
                select(
                    .id("visibility-\(content.id)"), .class("form-input"), .name("isPublished"),
                    .dataFlag("ck-submit-on-change")
                ) {
                    option(.value("true")) { "Visible" }.attributes(.selected, when: content.isPublished)
                    option(.value("false")) { "Hidden" }.attributes(.selected, when: !content.isPublished)
                }
            }
        }
    }

    private var editPopover: some HTML {
        details(.class("ext-details popup-anchor")) {
            summary(
                .class("btn action-btn action-btn-icon ext-summary"), .title("Edit"),
                .ariaLabel("Edit \(content.title)")
            ) { Icon("i-pencil") }
            div(.class("popover-panel")) {
                form(
                    .method(.post), .action("/instructor/content-items/\(content.id)/edit"),
                    .enctype(.multipartFormData), .class("form popup-form")
                ) {
                    CSRFField(token: csrfToken)
                    label(.class("form-label")) {
                        "Title"
                        input(
                            .class("form-input editor-input"), .type(.text), .name("title"), .value(content.title),
                            .required)
                    }
                    label(.class("form-label")) {
                        "Type"
                        select(.class("form-input editor-input"), .name("kind")) {
                            for kind in Self.kinds {
                                option(.value(kind.value)) { kind.label }
                                    .attributes(.selected, when: content.kind == kind.value)
                            }
                        }
                    }
                    div(.class("content-item-link-fields")) {
                        for link in content.links {
                            LinkPairFields(label: link.label, url: link.url)
                        }
                        LinkPairFields(label: nil, url: nil)
                    }
                    label(.class("form-label")) {
                        "Description"
                        input(
                            .class("form-input editor-input"), .type(.text), .name("description"),
                            .value(content.itemDescription ?? ""))
                    }
                    label(.class("form-label")) {
                        "Updated label"
                        input(
                            .class("form-input editor-input"), .type(.text), .name("updatedLabel"),
                            .value(content.updatedLabel ?? ""), .placeholder("e.g. 2026-05-11"))
                    }
                    label(.class("form-label")) {
                        "Visibility"
                        select(.class("form-input editor-input"), .name("isPublished")) {
                            option(.value("true")) { "Published" }.attributes(.selected, when: content.isPublished)
                            option(.value("false")) { "Hidden" }.attributes(.selected, when: !content.isPublished)
                        }
                    }
                    label(.class("form-label")) {
                        "Add files"
                        input(
                            .class("form-input editor-input"), .type(.file), .name("attachmentFiles"), .multiple)
                    }
                    button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save changes" }
                }
                if !content.attachments.isEmpty {
                    div(.class("content-item-attachment-list")) {
                        for attachment in content.attachments {
                            AttachmentRow(attachment: attachment, contentID: content.id, csrfToken: csrfToken)
                        }
                    }
                }
            }
        }
    }
}

/// One label and URL pair of a material's edit form. The trailing blank pair
/// carries no value.
private struct LinkPairFields: HTML {
    let label: String?
    let url: String?

    var body: some HTML {
        span(.class("content-item-link-pair")) {
            if let label, let url {
                input(
                    .class("form-input editor-input"), .type(.text), .name("linkLabels[]"), .value(label),
                    .placeholder("Label"))
                input(
                    .class("form-input editor-input"), .type(.text), .name("linkURLs[]"), .value(url),
                    .placeholder("https://…"))
            } else {
                input(.class("form-input editor-input"), .type(.text), .name("linkLabels[]"), .placeholder("Label"))
                input(.class("form-input editor-input"), .type(.text), .name("linkURLs[]"), .placeholder("https://…"))
            }
        }
    }
}

/// One hosted file on a material, with its Remove form.
private struct AttachmentRow: HTML {
    let attachment: ContentAttachmentView
    let contentID: String
    let csrfToken: String

    var body: some HTML {
        div(.class("content-item-attachment")) {
            a(.href(attachment.downloadURL)) { attachment.displayName }
            " "
            span(.class("text-muted content-item-attachment-size")) { attachment.sizeLabel }
            form(
                .method(.post), .action("/instructor/content-items/\(contentID)/attachments/\(attachment.id)/delete"),
                .data("confirm", value: "Remove this file?")
            ) {
                CSRFField(token: csrfToken)
                button(.class("btn action-btn action-danger"), .type(.submit)) { "Remove" }
            }
        }
    }
}

/// A graded assignment, or an unpublished setup (no assignment ID).
private struct CourseAssignmentItemRow: HTML {
    let row: AssignmentRow
    let enrolledStudentCount: Int
    let csrfToken: String
    let controls: DashboardControls

    private var statusClass: String {
        switch row.status {
        case "open": "status-open"
        case "preview": "status-preview"
        case "closed": "status-closed"
        default: ""
        }
    }

    var body: some HTML {
        tr(.class(statusClass)) {
            td(.class("section-items-handle")) {
                if row.assignmentID != nil {
                    span(.class("suite-drag-handle"), .ariaHidden) { "⋮⋮" }
                }
            }
            td(.class("item-tile-cell")) {
                if row.assignmentID != nil {
                    span(.class("item-tile"), .data("kind", value: "graded")) { Icon("i-calendar-check") }
                } else {
                    span(.class("item-tile")) { Icon("i-upload") }
                }
            }
            td(.class("item-main")) { mainCell }
            td(.class("item-status")) { statusCell }
            td(.class("col-hide-phone nowrap")) {
                if row.assignmentID != nil {
                    let submitted = row.submittedStudentCount.map(String.init) ?? ""
                    span(.title("\(submitted) / \(enrolledStudentCount) students submitted")) {
                        "\(submitted) / \(enrolledStudentCount)"
                    }
                    div(.class("item-details")) { "submitted" }
                }
            }
            td(.class("item-actions-td")) {
                if row.status == "unpublished" {
                    unpublishedActions
                } else {
                    // Every published status (open, closed, staff-only preview)
                    // gets the same actions: copy link and edit up front, the
                    // rest in the row menu.
                    publishedActions
                }
            }
        }
        .attributes(.data("assignment-id", value: row.assignmentID ?? ""), when: row.assignmentID != nil)
    }

    @HTMLBuilder private var mainCell: some HTML {
        if let assignmentID = row.assignmentID {
            div(.class("item-title")) { a(.href("/instructor/\(assignmentID)/submissions")) { row.title ?? "" } }
            div(.class("item-details")) {
                if let dueAt = row.dueAt { "Due \(dueAt)" } else { "No due date" }
                if row.variantState != "none" {
                    " · "
                    let note = "Reference solution graded on synthetic per-student seeds"
                    if row.variantState == "failed" {
                        span(.class("tier tier-danger"), .title(note)) { row.variantSummaryText }
                    } else {
                        span(.title(note)) { row.variantSummaryText }
                    }
                }
                if row.variantState == "failed" {
                    " · Students on those variants fail too"
                    if let failedID = row.failedVariantSubmissionID {
                        " · "
                        a(.href("/submissions/\(failedID)")) { "View variant" }
                    }
                }
                switch row.validationStatus {
                case "failed":
                    if let submissionID = row.validationSubmissionID {
                        " · "
                        a(.href("/submissions/\(submissionID)")) { "View results" }
                    }
                case "pending":
                    if let submissionID = row.validationSubmissionID {
                        " · "
                        a(.href("/submissions/\(submissionID)")) { "Track status" }
                    }
                case "no-runner":
                    " · Ask an admin for a compatible runner, then re-save."
                default:
                    ""
                }
            }
        } else {
            div(.class("item-title text-muted")) { em { "Unpublished" } }
            div(.class("item-details")) { "Uploaded \(row.createdAt) · \(row.suiteCount) tests" }
        }
    }

    @HTMLBuilder private var statusCell: some HTML {
        if let assignmentID = row.assignmentID {
            switch row.validationStatus {
            case "passed" where !controls.assignmentLifecycle:
                span(.class("tier \(statusTierClass)")) { statusLabel }
            case "passed":
                form(.method(.post), .action("/instructor/\(assignmentID)/status"), .class("status-form")) {
                    CSRFField(token: csrfToken)
                    label(.class("visually-hidden"), .for("status-\(assignmentID)")) {
                        "Status for \(row.title ?? "")"
                    }
                    span(.class("state-select"), .data("state", value: row.status)) {
                        select(
                            .id("status-\(assignmentID)"), .class("form-input"), .name("status"),
                            .dataFlag("ck-submit-on-change")
                        ) {
                            option(.value("open")) { "open" }.attributes(.selected, when: row.status == "open")
                            option(.value("preview")) { "staff only" }
                                .attributes(.selected, when: row.status == "preview")
                            option(.value("closed")) { "closed" }.attributes(.selected, when: row.status == "closed")
                        }
                    }
                }
            case "failed":
                span(.class("tier tier-danger")) { "Validation failed" }
            case "pending":
                span(.class("tier tier-preview")) { "Validating…" }
            case "no-runner":
                span(
                    .class("tier tier-danger"),
                    .title("No runner could grade this when it was last saved, so validation did not run.")
                ) { "No runner" }
            default:
                span(.class("tier tier-closed")) { "closed" }
            }
        } else {
            span(.class("tier tier-unpublished")) { "Unpublished" }
        }
    }

    /// The read-only status, for a viewer who may not change it.
    private var statusTierClass: String {
        switch row.status {
        case "open": "tier-open"
        case "preview": "tier-preview"
        default: "tier-closed"
        }
    }

    private var statusLabel: String {
        switch row.status {
        case "open": "open"
        case "preview": "staff only"
        default: "closed"
        }
    }

    private var unpublishedActions: some HTML {
        div(.class("assignment-actions-cell")) {
            if controls.createAssignment {
                publishDetails
            }
            if controls.assignmentLifecycle {
                RowMenu(for: "unpublished setup \(row.setupID)") {
                    form(
                        .method(.post), .action("/instructor/setup/\(row.setupID)/delete"),
                        .data("confirm", value: "Delete this unpublished setup? This cannot be undone.")
                    ) {
                        CSRFField(token: csrfToken)
                        button(
                            .class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")
                        ) {
                            Icon("i-trash")
                            "Delete setup"
                        }
                    }
                }
            }
        }
    }

    private var publishDetails: some HTML {
        details(.class("publish-details")) {
            summary(.class("btn action-btn summary-btn")) { "Publish…" }
            form(.class("publish-form"), .method(.post), .action("/instructor")) {
                input(.type(.hidden), .name("testSetupID"), .value(row.setupID))
                label(.class("form-label publish-label")) {
                    "Title"
                    input(
                        .class("form-input editor-input"), .type(.text), .name("title"),
                        .placeholder("e.g. Lab 1 — Warmup"), .required)
                }
                label(.class("form-label publish-label")) {
                    "Due date (optional)"
                    input(
                        .class("form-input js-publish-due-date editor-input"), .type(.datetimeLocal),
                        .name("dueAt"))
                }
                // Shown by Public/assignments.js when the date lands on a UW date.
                div(.class("publish-uw-warning card-meta"), .custom(name: "style", value: "display:none")) {}
                button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Create draft" }
            }
        }
    }

    private var publishedActions: some HTML {
        let assignmentID = row.assignmentID ?? ""
        return div(.class("assignment-actions-cell")) {
            button(
                .class("btn action-btn action-btn-icon"), .type(.button), .title("Copy student link"),
                .ariaLabel("Copy student link"), .data("copy-url", value: row.vanityURL ?? "")
            ) { Icon("i-link") }
            a(
                .class("btn action-btn action-btn-icon"), .href("/instructor/\(assignmentID)/workbench"),
                .title("Edit assignment"), .ariaLabel("Edit assignment")
            ) { Icon("i-pencil") }
            RowMenu(for: row.title ?? "") {
                if let leaderboardURL = row.leaderboardURL {
                    a(.class("row-menu-item"), .href(leaderboardURL), .role("menuitem")) {
                        Icon("i-award")
                        "Leaderboard"
                    }
                }
                if controls.createAssignment {
                    menuForm(
                        action: "/instructor/\(assignmentID)/clone",
                        confirm:
                            "Duplicate this assignment? A closed, unvalidated copy will be created for you to edit.",
                        icon: "i-copy", label: "Duplicate", danger: false)
                }
                menuForm(
                    action: "/instructor/\(assignmentID)/retest",
                    confirm:
                        "Retest every submission for this assignment? The worker will re-grade each one against the current test suite.",
                    icon: "i-refresh", label: "Retest all submissions", danger: false)
                if controls.assignmentLifecycle {
                    menuForm(
                        action: "/instructor/\(assignmentID)/delete",
                        confirm: "Delete this assignment? Students will no longer see it.",
                        icon: "i-trash", label: "Delete assignment", danger: true)
                }
            }
        }
    }

    private func menuForm(action: String, confirm: String, icon: String, label: String, danger: Bool) -> some HTML {
        form(.method(.post), .action(action), .data("confirm", value: confirm)) {
            CSRFField(token: csrfToken)
            button(
                .class(danger ? "row-menu-item row-menu-item--danger" : "row-menu-item"), .type(.submit),
                .role("menuitem")
            ) {
                Icon(icon)
                label
            }
        }
    }
}

// APIServer/Views/Pages/AssignmentsPage.swift
//
// GET /instructor: the instructor Overview tab. The dashboard cards, then the
// course's sections with their interleaved assignments and materials, then the
// ungrouped bucket. Public/section-items-dnd.js drives the drag reorder, and
// Public/assignments.js wires the cards, the section edit and delete
// controls, the copy-link buttons and the publish form's UW-date warning.

import Core
import Elementary

struct AssignmentsPage: HTML {
    let page: PageRequestContext
    /// Sections with their interleaved items.
    let sections: [CourseSectionRow]
    /// Assignments and materials in no section, interleaved and sorted.
    let ungroupedItems: [InstructorSectionItem]
    let hasSections: Bool
    /// True when there are ungrouped items, or no sections at all (flat-table
    /// mode).
    let showUngroupedBlock: Bool
    /// True only when the course has nothing to list in any lane.
    let showEmptyMessage: Bool
    let enrolledStudentCount: Int
    /// The published assignments a material's edit form offers under "Show on".
    var attachTargets: [AssignmentAttachTarget] = []
    /// From `?notice=`: what an action reported.
    var flash = FlashMessages()

    /// The staff dashboard also serves a TA, who is not offered a control
    /// that the server refuses.
    private var controls: DashboardControls { DashboardControls(viewer: page.currentUser) }

    private var heading: String {
        guard let course = page.currentUser?.activeCourse else { return "Assignments" }
        return "\(course.code) — \(course.name)"
    }

    var body: some HTML {
        BaseLayout(title: heading, page: page, flash: flash) {
            InstructorTabs(active: .overview)
            // Public/section-items-dnd.js keeps an assignment in its section
            // when the viewer may not move it to another one.
            section(
                .class("page-section"),
                .data("assignment-moves", value: controls.manageSections ? "free" : "locked")
            ) {
                h2(.class("page-heading")) { heading }
                div(.class("diagnostics-section")) {
                    div(.class("diagnostics-cards")) {
                        MetricsDiagnosticCard(
                            hook: .instructor, key: "submissions", label: "Submissions",
                            valueID: "idash-submissions")
                        MetricsDiagnosticCard(
                            hook: .instructor, key: "activeStudents", label: "Active Students",
                            valueID: "idash-active-students")
                        MetricsDiagnosticCard(
                            hook: .instructor, key: "activeAssignments", label: "Active Assignments",
                            valueID: "idash-active-assignments")
                        MetricsDiagnosticCard(
                            hook: .instructor, key: "browserErrors", label: "Browser Errors",
                            valueID: "idash-browser-errors")
                    }
                }
                if showEmptyMessage {
                    p(.class("empty")) {
                        if controls.createAssignment {
                            "No assignments yet. "
                            a(.href("/instructor/new")) { "Create one to get started." }
                        } else {
                            "No assignments yet. A course instructor creates them."
                        }
                    }
                } else {
                    div(.id("sections-container")) {
                        for section in sections {
                            SectionBlock(
                                section: section, enrolledStudentCount: enrolledStudentCount, csrfToken: page.csrfToken,
                                controls: controls, attachTargets: attachTargets)
                        }
                    }
                }
                if controls.manageSections {
                    addSectionToolbar
                }
                if !showEmptyMessage && showUngroupedBlock {
                    ungroupedBlock
                }
            }
            PageStyle(
                """
                .status-form {
                    display: inline-flex;
                    align-items: center;
                }
                .section-empty-row td {
                    cursor: default;
                }
                /* .add-section-details* and .section-block.section-dragging now live in the
                   global stylesheet (shared with the assignment editor). */
                """
            )
            script(.src(page.asset("/section-items-dnd.js"))) {}
            script(.src(page.asset("/assignments.js"))) {}
        }
    }

    private var addSectionToolbar: some HTML {
        div(.class("section-toolbar")) {
            details(.class("add-section-details popup-anchor"), .id("add-section-details")) {
                summary(.class("btn action-btn summary-btn")) { "+ Add Section" }
                div(.class("add-section-popup card suite-section-popup")) {
                    form(.method(.post), .action("/instructor/sections"), .class("form popup-form")) {
                        CSRFField(token: page.csrfToken)
                        label(.class("form-label")) {
                            "Section name"
                            input(
                                .class("form-input editor-input"), .type(.text), .name("name"),
                                .placeholder("e.g. Labs"), .required)
                        }
                        button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Create section" }
                    }
                }
            }
        }
    }

    private var ungroupedBlock: some HTML {
        div(.class("dashboard-block")) {
            div(.class("section-header")) {
                div(.class("section-view")) {
                    if hasSections {
                        h2(.class("ungrouped-heading")) { "Ungrouped" }
                    }
                    AddItemMenu(
                        newItemSectionID: controls.createAssignment ? "" : nil, panelID: "add-material-ungrouped")
                }
            }
            AddMaterialPanel(
                panelID: "add-material-ungrouped", sectionID: "", titlePlaceholder: "e.g. Course outline",
                csrfToken: page.csrfToken)
            if !ungroupedItems.isEmpty {
                SectionItemsTable(tbodyID: "assignments-body", sectionID: "") {
                    for item in ungroupedItems {
                        CourseItemRow(
                            item: item, enrolledStudentCount: enrolledStudentCount, csrfToken: page.csrfToken,
                            controls: controls, attachTargets: attachTargets)
                    }
                }
            }
        }
    }
}

/// One course section: its header (name, edit, + Add), the add-material
/// panel and its item table.
private struct SectionBlock: HTML {
    let section: CourseSectionRow
    let enrolledStudentCount: Int
    let csrfToken: String
    let controls: DashboardControls
    let attachTargets: [AssignmentAttachTarget]

    var body: some HTML {
        div(.class("section-block"), .data("section-id", value: section.sectionID)) {
            div(.class("section-header")) {
                span(.class("section-drag-handle"), .ariaHidden) { "⋮⋮" }
                div(.class("section-view")) {
                    strong { section.name }
                    if controls.manageSections {
                        button(
                            .class("btn-link js-section-edit-toggle icon-btn-text"), .type(.button),
                            .title("Edit section"), .ariaLabel("Edit section")
                        ) { Icon("i-pencil") }
                    }
                    AddItemMenu(
                        newItemSectionID: controls.createAssignment ? section.sectionID : nil,
                        panelID: "add-material-\(section.sectionID)")
                }
                if controls.manageSections {
                    editForm
                }
            }
            AddMaterialPanel(
                panelID: "add-material-\(section.sectionID)", sectionID: section.sectionID,
                titlePlaceholder: "e.g. Lecture 1", csrfToken: csrfToken)
            SectionItemsTable(tbodyID: nil, sectionID: section.sectionID) {
                if section.items.isEmpty {
                    tr(.class("section-empty-row")) {
                        td(.custom(name: "colspan", value: "6"), .class("section-empty-cell")) {
                            "Drag items here or use "
                            strong { "+ Add" }
                            " above"
                        }
                    }
                } else {
                    for item in section.items {
                        CourseItemRow(
                            item: item, enrolledStudentCount: enrolledStudentCount, csrfToken: csrfToken,
                            controls: controls, attachTargets: attachTargets)
                    }
                }
            }
        }
    }

    /// The rename form, hidden until Public/assignments.js shows it. Only for
    /// a viewer who may manage sections.
    private var editForm: some HTML {
        div(.class("section-edit"), .custom(name: "style", value: "display:none")) {
            form(
                .class("section-rename-form"), .method(.post),
                .action("/instructor/sections/\(section.sectionID)/rename")
            ) {
                CSRFField(token: csrfToken)
                input(
                    .class("form-input section-name-input"), .type(.text), .name("name"), .value(section.name),
                    .required)
                button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Save" }
            }
            button(
                .class("btn action-btn action-danger js-section-delete-btn"), .type(.button),
                .data("action", value: "/instructor/sections/\(section.sectionID)/delete"),
                .data("name", value: section.name)
            ) { "Delete" }
            button(
                .class("btn-link js-section-edit-cancel icon-btn-text"), .type(.button), .ariaLabel("Cancel"),
                .title("Cancel")
            ) { "✕" }
        }
    }
}

/// The "+ Add" menu: a new Assignment, Lab or Class activity, each opening
/// the create page with that type chosen, or a piece of material, which opens
/// the add-material panel `panelID`. A section names no default type; the
/// author picks the type here (docs/assignment-types.md). No graded items
/// when `newItemSectionID` is nil (a TA).
private struct AddItemMenu: HTML {
    /// The section a new graded item joins, "" for the ungrouped bucket, or
    /// nil when the viewer may not create one.
    let newItemSectionID: String?
    let panelID: String

    private func newItemHref(_ type: AssignmentType, sectionID: String) -> String {
        sectionID.isEmpty
            ? "/instructor/new?type=\(type.rawValue)"
            : "/instructor/new?type=\(type.rawValue)&sectionID=\(sectionID)"
    }

    private static let materials: [(kind: String, icon: String, label: String)] = [
        ("slides", "i-slides", "Slides"), ("notebook", "i-notebook", "Notebook"),
        ("document", "i-file-text", "Document"), ("link", "i-link", "Link"), ("outline", "i-list", "Outline"),
        ("heading", "i-heading", "Heading"),
    ]

    var body: some HTML {
        details(.class("add-section-details popup-anchor section-action--push")) {
            summary(.class("btn action-btn summary-btn")) {
                "+ Add "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                if let newItemSectionID {
                    div(.class("add-test-group-label")) { "Graded" }
                    for type in AssignmentType.allCases {
                        let tile = AssignmentTypeTile(type: type)
                        a(
                            .class("row-menu-item"), .href(newItemHref(type, sectionID: newItemSectionID)),
                            .role("menuitem")
                        ) {
                            span(.class("item-tile"), .data("kind", value: tile.kind)) { Icon(tile.symbol) }
                            type.displayName
                        }
                    }
                    hr()
                }
                div(.class("add-test-group-label")) { "Material" }
                for material in Self.materials {
                    a(
                        .class("row-menu-item"), .href("#\(panelID)"), .role("menuitem"),
                        .data("add-kind", value: material.kind), .data("add-target", value: panelID)
                    ) {
                        span(.class("item-tile"), .data("kind", value: material.kind)) { Icon(material.icon) }
                        material.label
                    }
                }
            }
        }
    }
}

/// The add-material form a "+ Add" menu item opens.
private struct AddMaterialPanel: HTML {
    let panelID: String
    /// The section the material joins; "" for the ungrouped bucket.
    let sectionID: String
    let titlePlaceholder: String
    let csrfToken: String

    var body: some HTML {
        div(.class("add-panel card"), .id(panelID)) {
            form(
                .method(.post), .action("/instructor/content-items"), .enctype(.multipartFormData),
                .class("form popup-form")
            ) {
                CSRFField(token: csrfToken)
                input(.type(.hidden), .name("sectionID"), .value(sectionID))
                label(.class("form-label")) {
                    "Title"
                    input(
                        .class("form-input editor-input"), .type(.text), .name("title"),
                        .placeholder(titlePlaceholder), .required)
                }
                label(.class("form-label")) {
                    "Type"
                    select(.class("form-input editor-input"), .name("kind")) {
                        option(.value("link")) { "Link" }
                        option(.value("notebook")) { "Notebook" }
                        option(.value("document")) { "Document" }
                        option(.value("slides")) { "Slides" }
                        option(.value("outline")) { "Outline" }
                        option(.value("heading")) { "Heading" }
                    }
                }
                div(.class("content-item-link-fields")) {
                    linkPair(labelPlaceholder: "Label (e.g. PDF)")
                    linkPair(labelPlaceholder: "Label (e.g. Notebook)")
                }
                label(.class("form-label")) {
                    "Description"
                    input(.class("form-input editor-input"), .type(.text), .name("description"))
                }
                label(.class("form-label")) {
                    "Updated label"
                    input(
                        .class("form-input editor-input"), .type(.text), .name("updatedLabel"),
                        .placeholder("e.g. 2026-05-11"))
                }
                label(.class("form-label")) {
                    "Visibility"
                    select(.class("form-input editor-input"), .name("isPublished")) {
                        option(.value("true")) { "Published" }
                        option(.value("false")) { "Hidden" }
                    }
                }
                label(.class("form-label")) {
                    "Files (optional)"
                    input(.class("form-input editor-input"), .type(.file), .name("attachmentFiles"), .multiple)
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Add material" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }

    private func linkPair(labelPlaceholder: String) -> some HTML {
        span(.class("content-item-link-pair")) {
            input(
                .class("form-input editor-input"), .type(.text), .name("linkLabels[]"),
                .placeholder(labelPlaceholder))
            input(.class("form-input editor-input"), .type(.text), .name("linkURLs[]"), .placeholder("https://…"))
        }
    }
}

/// The item table a section and the ungrouped bucket share.
private struct SectionItemsTable<Rows: HTML>: HTML {
    /// The ungrouped table's tbody id; nil for a section.
    let tbodyID: String?
    let sectionID: String
    let rows: Rows

    init(tbodyID: String?, sectionID: String, @HTMLBuilder rows: () -> Rows) {
        self.tbodyID = tbodyID
        self.sectionID = sectionID
        self.rows = rows()
    }

    var body: some HTML {
        table(.class("results-table section-items section-items--manage")) {
            colgroup {
                col(.class("section-items-handle"))
                col(.class("section-items-tile"))
                col()
                col(.class("section-items-status"))
                col(.class("section-items-count col-hide-phone"))
                col(.class("section-items-actions"))
            }
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Move" }
                    th(.custom(name: "scope", value: "col")) { "Type" }
                    th(.custom(name: "scope", value: "col")) { "Name" }
                    th(.custom(name: "scope", value: "col")) { "Status" }
                    th(.custom(name: "scope", value: "col"), .class("col-hide-phone")) { "Submitted" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            if let tbodyID {
                tbody(.id(tbodyID), .data("section-id", value: sectionID)) { rows }
            } else {
                tbody(.data("section-id", value: sectionID)) { rows }
            }
        }
    }
}

// APIServer/Views/Pages/InstructorGroupsPage.swift
//
// GET /instructor/groups: the Groups tab (docs/lab-groups.md, slice 1). The
// active course's group set, its groups with their student counts, and the
// forms that make a set, add or remove a group, and import a CSV file. A
// student moves between groups on the Students tab.

import Elementary

struct InstructorGroupsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    /// An instructor of a course that is not archived.
    let canEdit: Bool
    /// Why the viewer cannot edit, or nil when they can.
    let readOnlyNote: String?
    /// The course's group set, or nil before one is made.
    let groupSet: GroupSetPanel?

    var body: some HTML {
        BaseLayout(title: "Groups", page: page, flash: flash) {
            InstructorTabs(active: .groups)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its groups." }
                }
            } else if let groupSet {
                GroupSetSection(
                    csrfToken: page.csrfToken, panel: groupSet, canEdit: canEdit && groupSet.isManual,
                    readOnlyNote: groupSet.isManual ? readOnlyNote : "These groups come from LEARN.")
            } else {
                NoGroupSetSection(
                    csrfToken: page.csrfToken, courseCode: courseCode, canEdit: canEdit, readOnlyNote: readOnlyNote)
            }
        }
    }
}

/// The tab before the course has a group set: what a set is, and the form
/// that makes one.
private struct NoGroupSetSection: HTML {
    let csrfToken: String
    let courseCode: String
    let canEdit: Bool
    let readOnlyNote: String?

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) { h2 { "Groups" } }
            p(.class("section-intro")) {
                "Lab groups divide the students of \(courseCode) into the sections that meet together."
            }
            if canEdit {
                form(.method(.post), .action("/instructor/groups/sets"), .class("form-stack")) {
                    CSRFField(token: csrfToken)
                    label(.class("form-label")) {
                        "Name"
                        input(
                            .class("form-input"), .type(.text), .name("name"), .value("Lab sections"), .required,
                            .maxlength(CourseGroupStore.nameLimit))
                    }
                    div(.class("toolbar")) {
                        button(.class("btn btn-primary"), .type(.submit)) { "Create groups" }
                    }
                }
            } else {
                p(.class("empty")) { "No groups yet." }
                if let readOnlyNote { p(.class("section-note")) { readOnlyNote } }
            }
        }
    }
}

/// The course's group set: its groups, and the add and import panels.
private struct GroupSetSection: HTML {
    let csrfToken: String
    let panel: GroupSetPanel
    let canEdit: Bool
    let readOnlyNote: String?

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 {
                    "\(panel.name) "
                    span(.class("text-muted")) {
                        "\(panel.studentCount) students · \(panel.ungroupedCount) in no group"
                    }
                }
                if canEdit { GroupAddMenu() }
            }
            if let readOnlyNote { p(.class("section-note")) { readOnlyNote } }
            if canEdit {
                addPanel
                importPanel
            }
            if panel.groups.isEmpty {
                p(.class("empty")) { "No groups yet." }
                if canEdit { p(.class("section-note")) { "Add a group, or import a CSV file." } }
            } else {
                GroupRowsTable(csrfToken: csrfToken, groups: panel.groups, canEdit: canEdit)
            }
            if canEdit {
                p(.class("section-note")) {
                    "Move one student on the "
                    a(.href("/instructor/students")) { "Students" }
                    " tab."
                }
            }
        }
    }

    private var addPanel: some HTML {
        div(.class("add-panel card"), .id("group-add-panel")) {
            form(.method(.post), .action("/instructor/groups/add"), .class("form-stack")) {
                CSRFField(token: csrfToken)
                input(.type(.hidden), .name("setID"), .value(panel.id))
                label(.class("form-label")) {
                    "Name"
                    input(
                        .class("form-input"), .type(.text), .name("name"), .required,
                        .maxlength(CourseGroupStore.nameLimit), .placeholder("Lab 103"))
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Add" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }

    private var importPanel: some HTML {
        div(.class("add-panel card"), .id("group-import-panel")) {
            form(
                .method(.post), .action("/instructor/groups/import"), .enctype(.multipartFormData),
                .class("form-stack"),
                .data("confirm", value: "Replace every student's group with the groups in this file?")
            ) {
                CSRFField(token: csrfToken)
                input(.type(.hidden), .name("setID"), .value(panel.id))
                label(.class("form-label")) {
                    "CSV file"
                    input(.class("form-input"), .type(.file), .name("file"), .accept(".csv"), .required)
                    span(.class("field-note field-note--muted")) {
                        "The file replaces every student's group."
                    }
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Import" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }
}

/// The one "+ Add" menu: a group by name, or groups from a file. Each item
/// opens its add panel, as on the Students tab.
private struct GroupAddMenu: HTML {
    var body: some HTML {
        details(.class("add-section-details popup-anchor")) {
            summary(.class("btn action-btn summary-btn")) {
                "+ Add "
                Icon("i-chevron-down")
            }
            div(.class("add-section-popup card suite-section-popup row-menu-panel"), .role("menu")) {
                a(
                    .class("row-menu-item"), .href("#group-add-panel"), .role("menuitem"),
                    .data("add-target", value: "group-add-panel")
                ) {
                    span(.class("item-tile"), .data("kind", value: "outline")) { Icon("i-plus") }
                    span {
                        "Add group"
                        br()
                        span(.class("card-meta")) { "One group, by name" }
                    }
                }
                a(
                    .class("row-menu-item"), .href("#group-import-panel"), .role("menuitem"),
                    .data("add-target", value: "group-import-panel")
                ) {
                    span(.class("item-tile"), .data("kind", value: "document")) { Icon("i-upload") }
                    span {
                        "Import CSV"
                        br()
                        span(.class("card-meta")) { "Usernames and groups; replaces every group" }
                    }
                }
            }
        }
    }
}

/// One row per group: its name, its student count, and the remove action.
private struct GroupRowsTable: HTML {
    let csrfToken: String
    let groups: [GroupSetPanel.Row]
    let canEdit: Bool

    var body: some HTML {
        table(.class("results-table section-items section-items--manage")) {
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Type" }
                    th(.custom(name: "scope", value: "col")) { "Group" }
                    th(.custom(name: "scope", value: "col")) { "Actions" }
                }
            }
            tbody {
                for group in groups {
                    tr {
                        td(.class("item-tile-cell")) {
                            span(.class("item-tile"), .data("kind", value: "outline")) { Icon("i-layers") }
                        }
                        td(.class("item-main")) {
                            div(.class("item-title")) { group.name }
                            div(.class("item-details")) { group.countText }
                        }
                        td(.class("item-actions-td")) {
                            if canEdit { GroupRemoveMenu(csrfToken: csrfToken, group: group) }
                        }
                    }
                }
            }
        }
    }
}

/// A group's row menu, with the one action: remove the group.
private struct GroupRemoveMenu: HTML {
    let csrfToken: String
    let group: GroupSetPanel.Row

    var body: some HTML {
        div(.class("assignment-actions-cell")) {
            RowMenu(for: group.name) {
                form(
                    .method(.post), .action("/instructor/groups/remove"),
                    .data("confirm", value: "Remove \(group.name) and leave its students in no group?")
                ) {
                    CSRFField(token: csrfToken)
                    input(.type(.hidden), .name("groupID"), .value(group.id))
                    button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                        Icon("i-trash")
                        "Remove group"
                    }
                }
            }
        }
    }
}

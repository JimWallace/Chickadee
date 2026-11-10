// APIServer/Views/EditAssignmentTypeBlock.swift
//
// The assignment edit page's Type block: the declared Assignment, Lab or Class
// activity (docs/assignment-types.md). Authoring metadata, so it sits apart
// from the Student Options, on the same workbench sheet.

import Elementary

/// The Type select and its save button.
struct EditAssignmentTypeBlock: HTML {
    let edit: EditAssignmentContext
    let csrfToken: String

    var body: some HTML {
        section(.class("editor-block")) {
            div(.class("editor-block-head")) {
                h2 { "Type" }
            }
            form(
                .method(.post), .action("/instructor/\(edit.assignmentID)/assignment-type"),
                .dataFlag("ck-inplace")
            ) {
                CSRFField(token: csrfToken)
                " "
                label(.class("field-inline")) {
                    "Assignment type "
                    select(.name("assignmentType"), .class("form-input input-compact")) {
                        SelectOptions(options: edit.assignmentTypeOptions)
                    }
                    " "
                }
                p(.class("field-note field-note--muted")) {
                    "Sets the icon this assignment shows in the course lists."
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save type" }
            }
        }
    }
}

// APIServer/Views/EditAssignmentTypeBlock.swift
//
// The assignment edit page's Type block: the declared Assignment, Lab or Class
// activity (docs/assignment-types.md). The type decides how the work is graded
// and whether it counts, so the block states the current type's rules.

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
                    edit.assignmentTypeRules
                }
                button(.class("btn action-btn"), .type(.submit)) { "Save type" }
            }
        }
    }
}

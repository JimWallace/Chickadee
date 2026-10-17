// APIServer/Views/AddSuiteSectionPopup.swift
//
// "+ Section": a popup with one field that creates a suite section in place.
// The suite block of the edit page and the workbench rail both offer it.

import Elementary

struct AddSuiteSectionPopup: HTML {
    let assignmentID: String
    let csrfToken: String
    /// The `<details>` id, or nil. Only one copy on a page may carry it.
    var id: String?

    var body: some HTML {
        details(attributes: [.class("add-section-details popup-anchor")] + (id.map { [.id($0)] } ?? [])) {
            summary(.class("btn action-btn summary-btn")) { "+ Section" }
            div(.class("add-section-popup card suite-section-popup")) {
                form(
                    .method(.post), .action("/instructor/\(assignmentID)/suite-sections"),
                    .class("form popup-form"), .dataFlag("ck-inplace")
                ) {
                    CSRFField(token: csrfToken)
                    " "
                    label(.class("form-label")) {
                        "Section name "
                        input(
                            .class("form-input editor-input"), .type(.text), .name("name"),
                            .placeholder("e.g. Question 1"), .required)
                        " "
                    }
                    " "
                    button(.class("btn btn-primary btn-compact"), .type(.submit)) { "Create section" }
                }
            }
        }
    }
}

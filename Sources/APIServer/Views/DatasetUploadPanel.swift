// APIServer/Views/DatasetUploadPanel.swift
//
// The form that uploads a CSV on the Datasets tab: a new dataset on the
// list page, a new version on a dataset's page.

import Elementary

/// The form that uploads a file: a new dataset when `slug` is nil, else a new
/// version of that dataset.
struct DatasetUploadPanel: HTML {
    let page: PageRequestContext
    let panelID: String
    let action: String
    let slug: String?
    let submitLabel: String
    let maxUploadText: String

    var body: some HTML {
        div(.class("add-panel card"), .id(panelID)) {
            form(.method(.post), .action(action), .enctype(.multipartFormData), .class("form-stack")) {
                CSRFField(token: page.csrfToken)
                if let slug {
                    input(.type(.hidden), .name("slug"), .value(slug))
                } else {
                    label(.class("form-label")) {
                        "Name"
                        input(.class("form-input"), .type(.text), .name("name"), .required, .maxlength(200))
                    }
                    label(.class("form-label")) {
                        "Slug"
                        input(
                            .class("form-input"), .type(.text), .name("slug"), .maxlength(64),
                            .placeholder("Made from the name"))
                        span(.class("field-note field-note--muted")) {
                            "It cannot change later."
                        }
                    }
                }
                label(.class("form-label")) {
                    "CSV file"
                    input(.class("form-input"), .type(.file), .name("file"), .accept(".csv"), .required)
                    span(.class("field-note field-note--muted")) {
                        "At most \(maxUploadText)."
                    }
                }
                label(.class("form-label")) {
                    "Note"
                    input(
                        .class("form-input"), .type(.text), .name("note"),
                        .placeholder(slug == nil ? "Where this file came from" : "What changed"))
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { submitLabel }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }
}

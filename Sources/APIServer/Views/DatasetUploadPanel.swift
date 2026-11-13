// APIServer/Views/DatasetUploadPanel.swift
//
// The form that uploads a file on the Datasets tab: a new dataset on the
// list page, with its format, or a new version on a dataset's page, in the
// dataset's format (docs/fhir-datasets-plan.md §6).

import Core
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
    /// The dataset's format for a new version; nil for a new dataset, which
    /// chooses one.
    var format: DatasetFormat?

    /// The extensions the file picker offers.
    private var acceptText: String {
        (format.map { [$0] } ?? DatasetFormat.allCases).map { "." + $0.fileExtension }.joined(separator: ",")
    }

    private var fileLabel: String {
        format.map { "\($0.displayName) file" } ?? "File"
    }

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
                    label(.class("form-label")) {
                        "Format"
                        select(.class("form-input"), .name("format")) {
                            SelectOptions(
                                options: DatasetFormat.allCases.map {
                                    SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == .csv)
                                })
                        }
                        span(.class("field-note field-note--muted")) {
                            "FHIR NDJSON is one FHIR R4 resource per line."
                        }
                    }
                }
                label(.class("form-label")) {
                    fileLabel
                    input(
                        .class("form-input"), .type(.file), .name("file"), .custom(name: "accept", value: acceptText),
                        .required)
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

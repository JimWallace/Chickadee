// APIServer/Views/FHIRDictionarySection.swift
//
// The data dictionary of a FHIR dataset on its Datasets tab page
// (docs/fhir-datasets-plan.md §5): the resource types and the codes in use,
// each with the prose an editor writes, and the example resource that the
// student Data page shows. A CSV dataset has a column table instead
// (`InstructorDatasetPage`).
//
// The form posts every entry, so an entry left blank loses its prose. The
// keys go back as hidden fields in the summary's order.

import Core
import Elementary

struct FHIRDictionarySection: HTML {
    let page: PageRequestContext
    let slug: String
    let version: Int
    let summary: FHIRDatasetSummary

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Data dictionary" }
                button(.class("btn btn-primary"), .type(.submit), .form("dataset-dictionary")) { "Save" }
            }
            form(.method(.post), .action("/instructor/datasets/dictionary"), .id("dataset-dictionary")) {
                CSRFField(token: page.csrfToken)
                input(.type(.hidden), .name("slug"), .value(slug))
                input(.type(.hidden), .name("version"), .value(String(version)))
                h3 { "Resource types" }
                FHIRTypeTable(types: summary.resourceTypes)
                if summary.codes.isEmpty {
                    h3 { "Codes" }
                    p(.class("empty")) { "No resource has a code." }
                }
                for group in summary.codeGroups {
                    h3 { "Codes: \(group.name)" }
                    FHIRCodeTable(codes: group.codes)
                }
                if summary.omittedCodeCount > 0 {
                    p(.class("section-note")) { "\(summary.omittedCodeCount) more codes are not listed." }
                }
                if summary.danglingPatientReferences > 0 {
                    p(.class("section-note")) {
                        "\(summary.danglingPatientReferences) references name a patient that the file does not hold."
                    }
                }
                h3 { "Example resource" }
                FHIRExamplePicker(summary: summary)
            }
        }
    }
}

/// Each resource type, its count and its prose.
private struct FHIRTypeTable: HTML {
    let types: [FHIRDatasetSummary.TypeCount]

    var body: some HTML {
        div(.class("table-scroll")) {
            table(.class("results-table")) {
                thead {
                    tr {
                        th { "Type" }
                        th { "Count" }
                        th { "Description" }
                    }
                }
                tbody {
                    for type in types {
                        tr {
                            td {
                                code { type.resourceType }
                                input(.type(.hidden), .name("typeNames[]"), .value(type.resourceType))
                            }
                            td { String(type.count) }
                            td {
                                input(
                                    .class("form-input"), .type(.text), .name("typeDescriptions[]"),
                                    .value(type.description ?? ""),
                                    .ariaLabel("Description of \(type.resourceType)"))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The codes of one system: the code, the display, the resource type, the
/// units seen, the count and the prose. The same columns as the student Data
/// page, with the prose as a field.
private struct FHIRCodeTable: HTML {
    let codes: [FHIRDatasetSummary.CodeUse]

    var body: some HTML {
        div(.class("table-scroll")) {
            table(.class("results-table")) {
                thead {
                    tr {
                        th { "Code" }
                        th { "Display" }
                        th { "Resource" }
                        th { "Unit" }
                        th { "Count" }
                        th { "Description" }
                    }
                }
                tbody {
                    for entry in codes {
                        tr {
                            td {
                                code { entry.code }
                                input(.type(.hidden), .name("codeTypes[]"), .value(entry.resourceType))
                                input(.type(.hidden), .name("codeSystems[]"), .value(entry.system ?? ""))
                                input(.type(.hidden), .name("codeCodes[]"), .value(entry.code))
                            }
                            td { entry.display ?? "" }
                            td { entry.resourceType }
                            td { entry.units.joined(separator: ", ") }
                            td { String(entry.count) }
                            td {
                                input(
                                    .class("form-input"), .type(.text), .name("codeDescriptions[]"),
                                    .value(entry.description ?? ""),
                                    .ariaLabel("Description of \(entry.resourceType) \(entry.code)"))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The type and id of the example resource, and the example as students see
/// it. The type is one the file holds; the id is typed, because the summary
/// lists no ids.
private struct FHIRExamplePicker: HTML {
    let summary: FHIRDatasetSummary

    var body: some HTML {
        div(.class("toolbar")) {
            label(.class("form-label")) {
                "Resource type"
                select(.class("form-input"), .name("exampleType")) {
                    SelectOptions(
                        options: summary.resourceTypes.map {
                            SelectOption(
                                value: $0.resourceType, label: $0.resourceType,
                                selected: $0.resourceType == summary.example?.resourceType)
                        })
                }
            }
            label(.class("form-label")) {
                "Id"
                input(.class("form-input"), .type(.text), .name("exampleID"), .value(summary.example?.id ?? ""))
            }
        }
        if let text = summary.exampleText {
            pre(.class("test-output-pre")) { text }
        } else {
            p(.class("empty")) { "No example." }
            p(.class("section-note")) { "Name a resource of the newest version." }
        }
    }
}

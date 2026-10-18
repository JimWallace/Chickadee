// APIServer/Views/Pages/InstructorDatasetPage.swift
//
// GET /instructor/datasets/view?slug=: one dataset of the course library. Its
// facts and the form that edits them, the data dictionary of the newest
// version, every version with its download, and the assignments that attach
// it (docs/datasets-course-library.md §4.5).

import Core
import Elementary

struct InstructorDatasetPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let dataset: InstructorDatasetDetail
    /// The largest upload, as "16.0 MB".
    let maxUploadText: String

    var body: some HTML {
        BaseLayout(title: "\(dataset.name) — Datasets", page: page, flash: flash) {
            p(.class("page-crumb")) { a(.href("/instructor/datasets")) { "Datasets" } }
            DatasetHeader(page: page, dataset: dataset)
            p(.class("page-subtitle")) {
                code { dataset.slug }
                " · v\(dataset.currentVersion) · "
                if dataset.isPublished {
                    span(.class("tier tier-open")) { "Published" }
                } else {
                    span(.class("tier tier-unpublished")) { "Unpublished" }
                }
            }
            if !dataset.isPublished, !dataset.canPublish {
                p(.class("section-note")) { "Publishing needs a provenance and a licence." }
            }
            DatasetFacts(page: page, dataset: dataset)
            DatasetDictionarySection(page: page, dataset: dataset)
            DatasetVersionsSection(page: page, dataset: dataset, maxUploadText: maxUploadText)
            DatasetUsageSection(dataset: dataset)
        }
    }
}

/// The title bar: the name, the download and, for an editor, publish and the
/// more-actions menu.
private struct DatasetHeader: HTML {
    let page: PageRequestContext
    let dataset: InstructorDatasetDetail

    var body: some HTML {
        div(.class("page-titlebar")) {
            h1 { dataset.name }
            div(.class("toolbar")) {
                a(.class("btn action-btn"), .href(dataset.downloadHref)) {
                    Icon("i-download")
                    "Download"
                }
                publishForm
                // Delete is refused while an assignment attaches the
                // dataset, and the "Attached to" section says which.
                if dataset.usage.isEmpty {
                    moreMenu
                }
            }
        }
    }

    private var publishForm: some HTML {
        form(.method(.post), .action("/instructor/datasets/publish"), .class("form-flush")) {
            CSRFField(token: page.csrfToken)
            input(.type(.hidden), .name("slug"), .value(dataset.slug))
            input(.type(.hidden), .name("published"), .value(dataset.isPublished ? "0" : "1"))
            if dataset.isPublished {
                button(.class("btn action-btn"), .type(.submit)) { "Unpublish" }
            } else {
                button(.class("btn btn-primary"), .type(.submit)) { "Publish" }
                    .attributes(.disabled, when: !dataset.canPublish)
            }
        }
    }

    private var moreMenu: some HTML {
        RowMenu(for: dataset.name) {
            form(
                .method(.post), .action("/instructor/datasets/delete"),
                .data("confirm", value: "Delete \(dataset.name) and every version of it?")
            ) {
                CSRFField(token: page.csrfToken)
                input(.type(.hidden), .name("slug"), .value(dataset.slug))
                button(.class("row-menu-item row-menu-item--danger"), .type(.submit), .role("menuitem")) {
                    Icon("i-trash")
                    "Delete dataset"
                }
            }
        }
    }
}

/// The dataset's own fields as facts, with the form that edits them.
private struct DatasetFacts: HTML {
    let page: PageRequestContext
    let dataset: InstructorDatasetDetail

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "About" }
                a(
                    .class("btn action-btn"), .href("#dataset-about-panel"),
                    .data("add-target", value: "dataset-about-panel")
                ) { "Edit" }
            }
            editPanel
            dl(.class("detail-grid")) {
                dt { "Description" }
                dd { dataset.description ?? "None" }
                dt { "Provenance" }
                dd { dataset.provenance ?? "None" }
                dt { "Licence" }
                dd { dataset.licence ?? "None" }
            }
        }
    }

    private var editPanel: some HTML {
        div(.class("add-panel card"), .id("dataset-about-panel")) {
            form(.method(.post), .action("/instructor/datasets/metadata"), .class("form-stack")) {
                CSRFField(token: page.csrfToken)
                input(.type(.hidden), .name("slug"), .value(dataset.slug))
                label(.class("form-label")) {
                    "Name"
                    input(
                        .class("form-input"), .type(.text), .name("name"), .value(dataset.name), .required,
                        .maxlength(200))
                }
                label(.class("form-label")) {
                    "Description"
                    textarea(.class("form-input"), .name("description"), .rows(3)) { dataset.description ?? "" }
                }
                label(.class("form-label")) {
                    "Provenance"
                    input(
                        .class("form-input"), .type(.text), .name("provenance"), .value(dataset.provenance ?? ""),
                        .placeholder("Where the data came from"))
                }
                label(.class("form-label")) {
                    "Licence"
                    input(
                        .class("form-input"), .type(.text), .name("licence"), .value(dataset.licence ?? ""),
                        .placeholder("The licence or the terms of use"))
                    span(.class("field-note field-note--muted")) {
                        "Publishing needs both a provenance and a licence."
                    }
                }
                div(.class("toolbar")) {
                    button(.class("btn btn-primary"), .type(.submit)) { "Save" }
                    button(.class("btn action-btn js-add-cancel"), .type(.button)) { "Cancel" }
                }
            }
        }
    }
}

/// The newest version's columns: the inferred type, and the prose an editor
/// writes for each.
private struct DatasetDictionarySection: HTML {
    let page: PageRequestContext
    let dataset: InstructorDatasetDetail

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Data dictionary" }
                if !dataset.columns.isEmpty {
                    button(.class("btn btn-primary"), .type(.submit), .form("dataset-dictionary")) { "Save" }
                }
            }
            if dataset.columns.isEmpty {
                p(.class("empty")) { "No columns." }
            } else {
                form(.method(.post), .action("/instructor/datasets/dictionary"), .id("dataset-dictionary")) {
                    CSRFField(token: page.csrfToken)
                    input(.type(.hidden), .name("slug"), .value(dataset.slug))
                    input(.type(.hidden), .name("version"), .value(String(dataset.currentVersion)))
                    div(.class("table-scroll")) {
                        table(.class("results-table")) {
                            thead {
                                tr {
                                    th { "Column" }
                                    th { "Type" }
                                    th { "Description" }
                                    th { "Unit" }
                                }
                            }
                            tbody {
                                for column in dataset.columns {
                                    DatasetColumnRow(column: column)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One column of the dictionary: its name, its inferred type and its prose.
private struct DatasetColumnRow: HTML {
    let column: DatasetColumn

    var body: some HTML {
        tr {
            td {
                code { column.name }
                input(.type(.hidden), .name("columnNames[]"), .value(column.name))
            }
            td { span(.class("chip")) { column.valueType.rawValue } }
            td {
                input(
                    .class("form-input"), .type(.text), .name("columnDescriptions[]"),
                    .value(column.description ?? ""), .ariaLabel("Description of \(column.name)")
                )
            }
            td {
                input(
                    .class("form-input"), .type(.text), .name("columnUnits[]"), .value(column.unit ?? ""),
                    .ariaLabel("Unit of \(column.name)")
                )
            }
        }
    }
}

/// Every version, newest first, with the form that uploads the next one.
private struct DatasetVersionsSection: HTML {
    let page: PageRequestContext
    let dataset: InstructorDatasetDetail
    let maxUploadText: String

    var body: some HTML {
        section(.class("page-section")) {
            div(.class("page-titlebar")) {
                h2 { "Versions" }
                a(
                    .class("btn action-btn"), .href("#dataset-version-panel"),
                    .data("add-target", value: "dataset-version-panel")
                ) { "Add version" }
            }
            DatasetUploadPanel(
                page: page, panelID: "dataset-version-panel", action: "/instructor/datasets/versions",
                slug: dataset.slug, submitLabel: "Upload version", maxUploadText: maxUploadText)
            table(.class("results-table section-items")) {
                colgroup {
                    col()
                    col(.class("section-items-seen col-hide-phone"))
                    col(.class("section-items-actions"))
                }
                thead(.class("visually-hidden")) {
                    tr {
                        th(.custom(name: "scope", value: "col")) { "Version" }
                        th(.custom(name: "scope", value: "col")) { "Uploaded" }
                        th(.custom(name: "scope", value: "col")) { "Actions" }
                    }
                }
                tbody {
                    for version in dataset.versions {
                        tr {
                            td(.class("item-main")) {
                                div(.class("item-title")) { "v\(version.number)" }
                                div(.class("item-details")) { version.detailsText }
                                if let note = version.note {
                                    div(.class("item-details")) { note }
                                }
                            }
                            td(.class("col-hide-phone js-relative-time"), .data("iso", value: version.createdISO)) {
                                version.createdText
                            }
                            td(.class("item-actions-td")) {
                                a(
                                    .class("btn action-btn action-btn-icon"), .href(version.downloadHref),
                                    .title("Download"), .ariaLabel("Download v\(version.number)")
                                ) { Icon("i-download") }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The assignments and drafts that attach the dataset, with the version each
/// one pins.
private struct DatasetUsageSection: HTML {
    let dataset: InstructorDatasetDetail

    var body: some HTML {
        section(.class("page-section")) {
            h2 { "Attached to" }
            if dataset.usage.isEmpty {
                p(.class("empty")) { "No assignment attaches this dataset." }
            } else {
                table(.class("results-table section-items")) {
                    thead(.class("visually-hidden")) {
                        tr {
                            th(.custom(name: "scope", value: "col")) { "Assignment" }
                            th(.custom(name: "scope", value: "col")) { "Version" }
                        }
                    }
                    tbody {
                        for usage in dataset.usage {
                            tr {
                                td(.class("item-main")) {
                                    div(.class("item-title")) {
                                        if let editHref = usage.editHref {
                                            a(.href(editHref)) { usage.title }
                                        } else {
                                            usage.title
                                        }
                                    }
                                    div(.class("item-details")) { usage.detailsText }
                                }
                                td(.class("item-status")) {
                                    if usage.isBehind {
                                        span(.class("chip")) { "v\(dataset.currentVersion) available" }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// APIServer/Views/Pages/InstructorDatasetsPage.swift
//
// GET /instructor/datasets: the Datasets tab. The active course's dataset
// library, with the form that uploads a new dataset
// (docs/datasets-course-library.md §4.5). Each dataset opens its own page.

import Elementary

struct InstructorDatasetsPage: HTML {
    let page: PageRequestContext
    var flash = FlashMessages()
    let hasActiveCourse: Bool
    let courseCode: String
    let datasets: [InstructorDatasetRow]
    /// The largest upload, as "16.0 MB".
    let maxUploadText: String

    var body: some HTML {
        BaseLayout(title: "Datasets", page: page, flash: flash) {
            InstructorTabs(active: .datasets)
            if !hasActiveCourse {
                section(.class("page-section")) {
                    p(.class("empty")) { "Select a course to manage its datasets." }
                }
            } else {
                section(.class("page-section")) {
                    div(.class("page-titlebar")) {
                        h2 { "Datasets" }
                        a(
                            .class("btn action-btn"), .href("#dataset-new-panel"),
                            .data("add-target", value: "dataset-new-panel")
                        ) { "New dataset" }
                    }
                    p(.class("section-intro")) {
                        "Data files that the assignments in \(courseCode) attach, each at a pinned version."
                    }
                    DatasetUploadPanel(
                        page: page, panelID: "dataset-new-panel", action: "/instructor/datasets", slug: nil,
                        submitLabel: "Create dataset", maxUploadText: maxUploadText)
                    datasetList
                }
            }
        }
    }

    @HTMLBuilder private var datasetList: some HTML {
        if datasets.isEmpty {
            p(.class("empty")) { "No datasets yet." }
            p(.class("section-note")) { "Upload a CSV to create one." }
        } else {
            table(.class("results-table section-items")) {
                thead(.class("visually-hidden")) {
                    tr {
                        th(.custom(name: "scope", value: "col")) { "Type" }
                        th(.custom(name: "scope", value: "col")) { "Dataset" }
                        th(.custom(name: "scope", value: "col")) { "Visibility" }
                    }
                }
                tbody {
                    for dataset in datasets {
                        tr {
                            td(.class("item-tile-cell")) {
                                span(.class("item-tile"), .data("kind", value: "document")) { Icon("i-layers") }
                            }
                            td(.class("item-main")) {
                                div(.class("item-title")) { a(.href(dataset.href)) { dataset.name } }
                                div(.class("item-details")) {
                                    code { dataset.slug }
                                    " · \(dataset.detailsText) · \(dataset.usageText)"
                                }
                            }
                            td(.class("item-status")) {
                                if dataset.isPublished {
                                    span(.class("tier tier-open")) { "Published" }
                                } else {
                                    span(.class("tier tier-unpublished")) { "Unpublished" }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

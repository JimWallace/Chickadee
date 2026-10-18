// APIServer/Views/Pages/CourseDataPage.swift
//
// GET /data/:courseKey: the course's datasets as students read them
// (docs/datasets-course-library.md §4.6). For each dataset: what it is, where
// it came from, its licence, the data dictionary, and a download of the
// viewer's own rows in each assignment that uses it.

import Core
import Elementary

struct CourseDataPage: HTML {
    let page: PageRequestContext
    let courseCode: String
    let datasets: [CourseDataEntry]

    var body: some HTML {
        BaseLayout(title: "Data — \(courseCode)", page: page) {
            h1 { "Data" }
            p(.class("section-intro")) { "The datasets published for the assignments in \(courseCode)." }
            if datasets.isEmpty {
                p(.class("empty")) { "No datasets yet." }
                p(.class("section-note")) { "A dataset appears here when an instructor publishes it." }
                p { a(.href("/")) { "Back to your assignments" } }
            } else {
                for dataset in datasets {
                    CourseDataSection(dataset: dataset)
                }
            }
        }
    }
}

/// One dataset: its facts, its dictionary and the viewer's downloads.
private struct CourseDataSection: HTML {
    let dataset: CourseDataEntry

    var body: some HTML {
        section(.class("page-section")) {
            h2 {
                dataset.name
                if !dataset.isPublished {
                    " "
                    span(.class("tier tier-unpublished")) { "Unpublished" }
                }
            }
            if let description = dataset.description {
                p { description }
            }
            dl(.class("detail-grid")) {
                if let provenance = dataset.provenance {
                    dt { "Provenance" }
                    dd { provenance }
                }
                if let licence = dataset.licence {
                    dt { "Licence" }
                    dd { licence }
                }
                dt { "Rows" }
                dd { dataset.rowsText }
            }
            if !dataset.columns.isEmpty {
                CourseDataDictionary(columns: dataset.columns)
            }
            h3 { "Your rows" }
            if dataset.downloads.isEmpty {
                p(.class("empty")) { "No assignment you can open uses this dataset yet." }
            } else {
                CourseDataDownloads(downloads: dataset.downloads)
            }
        }
    }
}

/// The viewer's rows in each assignment, in the shared row shape: the
/// assignment, the file, and a Download button in the actions track.
private struct CourseDataDownloads: HTML {
    let downloads: [CourseDataEntry.Download]

    var body: some HTML {
        table(.class("results-table section-items")) {
            thead(.class("visually-hidden")) {
                tr {
                    th(.custom(name: "scope", value: "col")) { "Assignment" }
                    th(.custom(name: "scope", value: "col")) { "Download" }
                }
            }
            tbody {
                for download in downloads {
                    tr {
                        td(.class("item-main")) {
                            div(.class("item-title")) { download.assignmentTitle }
                            div(.class("item-details")) { code { download.filename } }
                        }
                        td(.class("item-actions-td")) {
                            div(.class("assignment-actions-cell")) {
                                a(
                                    .class("btn action-btn"), .href(download.href),
                                    .ariaLabel(
                                        "Download your rows of \(download.filename) in \(download.assignmentTitle)")
                                ) {
                                    Icon("i-download")
                                    "Download"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The data dictionary as a read-only table.
private struct CourseDataDictionary: HTML {
    let columns: [DatasetColumn]

    var body: some HTML {
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
                    for column in columns {
                        tr {
                            td { code { column.name } }
                            td { span(.class("chip")) { column.valueType.rawValue } }
                            td { column.description ?? "" }
                            td { column.unit ?? "" }
                        }
                    }
                }
            }
        }
    }
}

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
            p(.class("section-intro")) { "The datasets that the assignments in \(courseCode) use." }
            if datasets.isEmpty {
                p(.class("empty")) { "No datasets yet." }
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
                p(.class("empty")) { "No open assignment uses this dataset yet." }
            } else {
                ul {
                    for download in dataset.downloads {
                        li {
                            a(.href(download.href)) { download.assignmentTitle }
                            " · "
                            code { download.filename }
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

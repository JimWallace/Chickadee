// APIServer/Routes/Web/InstructorDatasetRow.swift
//
// One dataset as the Datasets tab lists it (`InstructorDatasetsPage`). Every
// string is formatted here, so the view only lays it out.

import Foundation

/// One dataset on the list page.
struct InstructorDatasetRow: Sendable {
    let slug: String
    let name: String
    let isPublished: Bool
    /// "v3 · 1204 rows · 45 KB"
    let detailsText: String
    /// "2 assignments", or "Not attached"
    let usageText: String

    var href: String { InstructorDatasetDetail.href(slug: slug) }

    init(slug: String, name: String, isPublished: Bool, detailsText: String, usageText: String) {
        self.slug = slug
        self.name = name
        self.isPublished = isPublished
        self.detailsText = detailsText
        self.usageText = usageText
    }

    init(dataset: APICourseDataset, newest: APICourseDatasetVersion?, usageCount: Int) {
        var details = ["v\(dataset.currentVersion)"]
        if let newest {
            details.append(InstructorDatasetDetail.rowsText(newest.rowCount))
            details.append(formatBytes(newest.sizeBytes))
        }
        self.init(
            slug: dataset.slug, name: dataset.name, isPublished: dataset.isPublished,
            detailsText: details.joined(separator: " · "),
            usageText: InstructorDatasetDetail.usageText(count: usageCount))
    }
}

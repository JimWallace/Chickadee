// APIServer/Routes/Web/CourseDataEntry.swift
//
// One dataset as the course Data page shows it (`CourseDataPage`,
// docs/datasets-course-library.md §4.6). Every string is formatted here, so
// the view only lays it out.

import Core
import Foundation

struct CourseDataEntry: Sendable {
    /// The student's rows in one assignment that attaches the dataset.
    struct Download: Sendable {
        let assignmentTitle: String
        let filename: String
        let href: String
    }

    let name: String
    let description: String?
    let provenance: String?
    let licence: String?
    /// Staff see an unpublished dataset, marked as such; students never do.
    let isPublished: Bool
    /// "1204 rows", or "300 patients" for FHIR, of the newest version
    let rowsText: String
    /// The newest version's dictionary, for a CSV dataset.
    let columns: [DatasetColumn]
    /// One per assignment the viewer can see that attaches the dataset, by
    /// title.
    let downloads: [Download]
    /// The newest version's summary and dictionary, for a FHIR dataset
    /// (docs/fhir-datasets-plan.md §5).
    var fhir: FHIRDatasetSummary?

    /// The download of `filename` in the assignment of `setupID`: `mine.csv`,
    /// or `mine.ndjson` for a FHIR file (`StudentDataRoutes`).
    static func downloadHref(setupID: String, filename: String, format: DatasetFormat) -> String {
        "/testsetups/\(urlEncode(setupID))/data/\(urlEncode(filename))/mine.\(format.fileExtension)"
    }
}

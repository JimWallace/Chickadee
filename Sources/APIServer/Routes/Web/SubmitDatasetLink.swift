// APIServer/Routes/Web/SubmitDatasetLink.swift
//
// One dataset file on the upload page: the student's own rows of it in this
// assignment (docs/datasets-course-library.md §4.6).

import Core
import Foundation

struct SubmitDatasetLink: Sendable {
    let filename: String
    /// "150 rows", "one part of 4" for a partition, or "every row" for a
    /// spec with no sample.
    let rowsText: String
    let href: String

    init(spec: DatasetSpec, setupID: String) {
        filename = spec.file
        if let partCount = spec.partCount, spec.kind == .partition {
            rowsText = "one part of \(partCount)"
        } else {
            rowsText = spec.sampleSize.map(InstructorDatasetDetail.rowsText) ?? "every row"
        }
        href = CourseDataEntry.downloadHref(setupID: setupID, filename: spec.file)
    }
}

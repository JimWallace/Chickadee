// APIServer/Routes/Web/SubmitDatasetLink.swift
//
// One dataset file on the upload page: the student's own rows of it in this
// assignment (docs/datasets-course-library.md §4.6).

import Core
import Foundation

struct SubmitDatasetLink: Sendable {
    let filename: String
    /// "150 rows", "one part of 4" for a partition, "every row" for a spec
    /// with no sample, or "every patient" for a FHIR file, which is
    /// delivered whole (docs/fhir-datasets-plan.md §11, decision 1).
    let rowsText: String
    let href: String

    init(spec: DatasetSpec, setupID: String) {
        filename = spec.file
        if !spec.capabilities.selects {
            rowsText = "every \(spec.capabilities.unitName)"
        } else if let partCount = spec.partCount, spec.kind == .partition {
            rowsText = "one part of \(partCount)"
        } else {
            rowsText = spec.sampleSize.map(InstructorDatasetDetail.rowsText) ?? "every row"
        }
        href = CourseDataEntry.downloadHref(setupID: setupID, filename: spec.file, format: spec.format)
    }
}

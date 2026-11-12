// APIServer/Migrations/AddCourseDatasetFormat.swift
//
// A course library dataset records its format, CSV or FHIR NDJSON
// (docs/fhir-datasets-plan.md §6, P2), and a FHIR version records its summary.
//
// - `course_datasets.format`: text, not null, database default 'csv'. Every
//   existing dataset is a CSV, and the old color of a blue-green deploy, which
//   does not map the column, creates a CSV dataset during the overlap.
// - `course_dataset_versions.summary_json`: nullable text, the encoded
//   `FHIRDatasetSummary` of a FHIR version. Null for a CSV version, whose
//   dictionary stays in `columns_json`.
//
// During the overlap the old color does not read `format` either: it would
// clone a FHIR dataset as CSV and export it in a version 2 bundle. A FHIR
// dataset exists only after this release creates one, and the overlap is
// minutes long, so the rule is: create no FHIR dataset until the deploy
// finishes. No page offers one before P3 in any case.
//
// Schema only: no row changes.

import Fluent

struct AddCourseDatasetFormat: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("course_datasets")
            .field("format", .string, .required, .custom("DEFAULT 'csv'"))
            .update()
        try await database.schema("course_dataset_versions")
            .field("summary_json", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("course_dataset_versions")
            .deleteField("summary_json")
            .update()
        try await database.schema("course_datasets")
            .deleteField("format")
            .update()
    }
}

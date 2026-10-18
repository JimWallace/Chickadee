// APIServer/Migrations/CreateCourseDatasets.swift
//
// Net-new tables for the course dataset library
// (docs/datasets-course-library.md, slice 2): one row per dataset in a
// course, and one row per uploaded version of it. The bytes of a version are a
// content-addressed blob (`AssignmentVersionBlobStore`), named by `sha256`.
//
// Both foreign keys cascade, so deleting a course removes its library rows. The
// blobs stay until `AssignmentVersionStore.reclaimOrphanedBlobs` runs after the
// delete, which counts dataset versions as references.

import Fluent

struct CreateCourseDatasets: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("course_datasets")
            .id()
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            // Unique per course. A spec names its source by slug, so a slug is
            // what survives a course clone and a bundle import.
            .field("slug", .string, .required)
            .field("name", .string, .required)
            .field("description", .string)
            .field("provenance", .string)
            .field("licence", .string)
            // A dataset is shown to students only when published, and it can be
            // published only with a provenance and a licence (D8).
            .field("is_published", .bool, .required)
            // The newest version number. Versions start at 1.
            .field("current_version", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "course_id", "slug")
            .create()

        try await database.schema("course_dataset_versions")
            .id()
            .field(
                "dataset_id", .uuid, .required, .references("course_datasets", "id", onDelete: .cascade)
            )
            .field("version", .int, .required)
            // The filename an attachment uses unless it names another.
            .field("filename", .string, .required)
            .field("sha256", .string, .required)
            .field("size_bytes", .int, .required)
            .field("row_count", .int, .required)
            // JSON-encoded `[DatasetColumn]`: the data dictionary.
            .field("columns_json", .string, .required)
            .field("note", .string)
            .field("created_at", .datetime)
            .unique(on: "dataset_id", "version")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("course_dataset_versions").delete()
        try await database.schema("course_datasets").delete()
    }
}

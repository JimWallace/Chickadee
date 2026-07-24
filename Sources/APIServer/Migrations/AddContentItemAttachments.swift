// APIServer/Migrations/AddContentItemAttachments.swift
//
// Adds the optional `attachments_json` column to the course_content_items
// table: a JSON-encoded `[ContentAttachment]` for instructor-uploaded (or
// agent-fetched) files hosted on the server, served through the gated
// /content-files route. Nullable — a NULL reads as `[]` through the model's
// `attachments` accessor.
//
// Standalone Add* migration (not folded into CreateCourseContentItems) because
// production databases have already applied CreateCourseContentItems without
// this column and would never pick it up from a body change. Fresh deploys run
// CreateCourseContentItems then this migration; existing prod runs only this.

import Fluent

struct AddContentItemAttachments: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_content_items")
            .field("attachments_json", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_content_items")
            .deleteField("attachments_json")
            .update()
    }
}

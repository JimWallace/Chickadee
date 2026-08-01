// APIServer/Migrations/CreateCourseContentItems.swift
//
// Net-new table for ungraded course content items — reference material (links,
// notebooks, slides, outlines) shown inside a course section alongside graded
// assignments. FK to `courses` (cascade) and `course_sections` (set null),
// mirroring how `assignments` references its section. Net-new for both fresh
// and existing deploys.

import Fluent

struct CreateCourseContentItems: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_content_items")
            .id()
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            // Nullable for ungrouped items; ON DELETE SET NULL so removing a
            // section leaves its content items in the trailing Ungrouped bucket
            // (matches assignments.section_id).
            .field(
                "section_id",
                .uuid,
                .references("course_sections", "id", onDelete: .setNull)
            )
            .field("sort_order", .int, .required)
            .field("title", .string, .required)
            .field("kind", .string, .required)
            .field("description", .string)
            .field("links_json", .string, .required)
            .field("updated_label", .string)
            .field("is_published", .bool, .required)
            // Folded from AddContentItemAttachments: JSON-encoded
            // `[ContentAttachment]` for hosted files served via the gated
            // /content-files route. NULL reads as `[]` through the model.
            .field("attachments_json", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_content_items").delete()
    }
}

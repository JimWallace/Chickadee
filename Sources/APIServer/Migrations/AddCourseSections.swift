// APIServer/Migrations/AddCourseSections.swift
//
// Adds the course_sections table and a nullable section_id column to assignments.
// Existing assignments have section_id = NULL (ungrouped) — no data loss.

import Fluent

struct AddCourseSections: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_sections")
            .id()
            .field("name",                  .string, .required)
            .field("default_grading_mode",  .string, .required)
            .field("sort_order",            .int,    .required)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("created_at", .datetime)
            .create()

        try await database.schema("assignments")
            .field(
                "section_id",
                .uuid,
                .references("course_sections", "id", onDelete: .setNull)
            )
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("section_id")
            .update()
        try await database.schema("course_sections").delete()
    }
}

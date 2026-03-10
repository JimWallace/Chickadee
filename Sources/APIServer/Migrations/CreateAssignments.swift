// APIServer/Migrations/CreateAssignments.swift
//
// An "assignment" is a test setup that an instructor has published to students.
// Students only see test setups that have a corresponding open assignment.

import Fluent

struct CreateAssignments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .id()
            .field("public_id", .string, .required)
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field("title",         .string,   .required)
            .field("due_at",        .datetime)
            .field("is_open",       .bool,     .required)
            .field("validation_status", .string)
            .field(
                "validation_submission_id",
                .string,
                .references("submissions", "id", onDelete: .setNull)
            )
            .field("sort_order",    .int)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("created_at",    .datetime)
            .unique(on: "public_id")
            .unique(on: "test_setup_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments").delete()
    }
}

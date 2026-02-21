// APIServer/Migrations/CreateAssignments.swift
//
// An "assignment" is a test setup that an instructor has published to students.
// Students only see test setups that have a corresponding open assignment.

import Fluent

struct CreateAssignments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .id()
            .field("test_setup_id", .string,   .required)
            .field("title",         .string,   .required)
            .field("due_at",        .datetime)
            .field("is_open",       .bool,     .required)
            .field("created_at",    .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments").delete()
    }
}

// APIServer/Migrations/CreateAssignmentExtensions.swift
//
// Per-student deadline extension table.  One row per (assignment, user)
// enforced by the composite UNIQUE constraint; the `extended_due_at`
// timestamp is the new deadline for that specific student.

import Fluent
import SQLKit

struct CreateAssignmentExtensions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignment_extensions")
            .id()
            .field(
                "assignment_id",
                .uuid,
                .required,
                .references("assignments", "id", onDelete: .cascade)
            )
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("extended_due_at", .datetime, .required)
            .field("note", .string)
            .field(
                "granted_by_user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("granted_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_assignment_extensions_user ON assignment_extensions(user_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_assignment_extensions_user").run()
        }
        try await database.schema("assignment_extensions").delete()
    }
}

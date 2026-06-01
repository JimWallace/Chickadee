// APIServer/Migrations/CreateGradeOverrides.swift
//
// Per-student grade override table.  One row per (test_setup, user)
// enforced by the composite UNIQUE constraint; `override_percent` is the
// whole-number percent (0–100) that replaces the runner-assigned grade for
// that student on that assignment.

import Fluent
import SQLKit

struct CreateGradeOverrides: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("grade_overrides")
            .id()
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("override_percent", .int, .required)
            .field("note", .string)
            .field(
                "granted_by_user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("granted_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "test_setup_id", "user_id")
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_grade_overrides_user ON grade_overrides(user_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_grade_overrides_user").run()
        }
        try await database.schema("grade_overrides").delete()
    }
}

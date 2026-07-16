// APIServer/Migrations/CreateBrightSpaceGradeClears.swift
//
// Queue of pending BrightSpace grade removals — one row per (test_setup, user)
// whose Chickadee grade source was removed (an override cleared on a student
// with no submissions) after Chickadee had pushed a grade.  The grade-sync
// sweep DELETEs the D2L grade value and removes the row.

import Fluent
import SQLKit

struct CreateBrightSpaceGradeClears: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("brightspace_grade_clears")
            .id()
            .field(
                "test_setup_id", .string, .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("brightspace_sync_pending", .bool)
            .field("brightspace_pending_since", .datetime)
            .field("brightspace_synced_at", .datetime)
            .field("brightspace_sync_error", .string)
            .field("created_at", .datetime)
            .unique(on: "test_setup_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("brightspace_grade_clears").delete()
    }
}

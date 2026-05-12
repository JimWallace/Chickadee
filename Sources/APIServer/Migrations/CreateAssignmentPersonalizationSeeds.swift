// APIServer/Migrations/CreateAssignmentPersonalizationSeeds.swift
//
// Phase 1 of issue #461 — per-student assignment seed.
// One row per (user, assignment); seed is a 64-char hex string (32 random bytes).
// Generated lazily on first grading attempt; stable for the lifetime of the
// (user, assignment) pair. Cascade-deletes follow the parent user / assignment.

import Fluent

struct CreateAssignmentPersonalizationSeeds: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignment_personalization_seeds")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field(
                "assignment_id",
                .uuid,
                .required,
                .references("assignments", "id", onDelete: .cascade)
            )
            .field("seed_value", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "assignment_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignment_personalization_seeds").delete()
    }
}

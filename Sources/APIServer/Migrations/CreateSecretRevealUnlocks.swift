// APIServer/Migrations/CreateSecretRevealUnlocks.swift
//
// Secret-reveal token spends: one row per (user, assignment) recording that
// the student cashed in their one reveal token, unlocking itemized secret-tier
// results on all of their submissions for that assignment. Row existence is
// the spent state; staff re-grant by deleting the row. Cascade-deletes follow
// the parent user / assignment.

import Fluent

struct CreateSecretRevealUnlocks: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("secret_reveal_unlocks")
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
            .field("spent_at", .datetime)
            .unique(on: "user_id", "assignment_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("secret_reveal_unlocks").delete()
    }
}

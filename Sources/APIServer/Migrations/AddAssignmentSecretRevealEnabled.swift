// APIServer/Migrations/AddAssignmentSecretRevealEnabled.swift
//
// Adds the optional `secret_reveal_enabled` column to the assignments table:
// the per-assignment instructor toggle that lets each student spend their one
// secret-reveal token to see secret-tier test results. nil/false = off (the
// default) — secret results stay aggregate-only for students.
//
// Shipped as a standalone Add* migration (not folded into CreateAssignments)
// for the same reason as AddAssignmentStartsAt: production databases have
// already applied CreateAssignments without this column and would never pick
// it up from a body change. Fresh deploys run CreateAssignments then this
// migration; existing prod runs only this one.

import Fluent

struct AddAssignmentSecretRevealEnabled: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("secret_reveal_enabled", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("secret_reveal_enabled")
            .update()
    }
}

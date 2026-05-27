// APIServer/Migrations/AddAssignmentStartsAt.swift
//
// Adds the optional `starts_at` column to the assignments table: an
// automatic open date. nil = open as soon as the assignment is published.
//
// Shipped as a standalone Add* migration (not folded into
// CreateAssignments) because production databases have already applied
// CreateAssignments without this column and would never pick it up from a
// body change. Fresh deploys run CreateAssignments then this migration;
// existing prod runs only this one. A future consolidation can fold the
// column into CreateAssignments once every deploy has applied this.

import Fluent

struct AddAssignmentStartsAt: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("starts_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("starts_at")
            .update()
    }
}

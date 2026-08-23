// APIServer/Migrations/AddAssignmentSolutionVisibility.swift
//
// Per-assignment solution-reveal policy: whether students may view the
// reference solution after the deadline (`SolutionVisibility` raw string).
// Nullable so every pre-existing assignment decodes as "hidden" — the
// staff-only behaviour they have always had.
//
// Fold into CreateAssignments in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent

struct AddAssignmentSolutionVisibility: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("solution_visibility", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("solution_visibility")
            .update()
    }
}

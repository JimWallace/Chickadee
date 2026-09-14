// APIServer/Migrations/AddAssignmentPassingThreshold.swift
//
// Per-assignment advisory passing threshold: the best-grade percentage at or
// above which the instructor pages show a student as passing. Nullable so
// every pre-existing assignment decodes as "no threshold" — the passing
// concept is off until an instructor sets one. Display-only: it never
// changes a grade.
//
// Fold into CreateAssignments in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent

struct AddAssignmentPassingThreshold: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("passing_threshold_percent", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("passing_threshold_percent")
            .update()
    }
}

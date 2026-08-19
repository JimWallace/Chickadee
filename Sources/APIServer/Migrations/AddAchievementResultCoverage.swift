// APIServer/Migrations/AddAchievementResultCoverage.swift
//
// The coverage half of a UNION class goal's snapshot: how many distinct items
// the class had covered when the sweep ran, and how many the goal asks for.
//
// Both nullable, so every pre-existing snapshot decodes as "not a union goal"
// and a grade-counted goal keeps writing neither.
//
// They are stored rather than recomputed at read time because a snapshot
// FREEZES at the deadline and its progress rides into the LEARN grade push. A
// frozen row that cannot say what coverage it froze at is not auditable — and
// recomputing later would read today's coverage table against yesterday's
// frozen bonus, which is exactly the mismatch the freeze exists to prevent.
//
// One column per ALTER — SQLite can't add multiple columns in one statement.

import Fluent

struct AddAchievementResultCoverage: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("achievement_results")
            .field("items_covered", .int)
            .update()
        try await database.schema("achievement_results")
            .field("items_required", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("achievement_results")
            .deleteField("items_covered")
            .update()
        try await database.schema("achievement_results")
            .deleteField("items_required")
            .update()
    }
}

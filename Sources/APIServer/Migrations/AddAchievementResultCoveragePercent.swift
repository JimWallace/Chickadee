// APIServer/Migrations/AddAchievementResultCoveragePercent.swift
//
// The coverage half of a CLASS-CORPUS goal's snapshot: what percent of the
// reference the class's combined contributions covered when the sweep ran, and
// what percent the goal asks for.
//
// Separate columns from `items_covered` / `items_required` because they count a
// different thing. Those two are integer counts of distinct suite items a union
// goal accumulated; these are percents one corpus run produced. Folding a
// percent into a column named for an item count would make every frozen row
// ambiguous about which kind of goal produced it.
//
// Both nullable, so every pre-existing snapshot decodes as "not a coverage
// goal", and stored rather than recomputed for the same reason the union pair
// is: a snapshot freezes at the deadline and its progress rides into the LEARN
// grade push, so a frozen row has to be able to say what it froze at.
//
// One column per ALTER — SQLite can't add multiple columns in one statement.

import Fluent

struct AddAchievementResultCoveragePercent: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("achievement_results")
            .field("coverage_percent", .double)
            .update()
        try await database.schema("achievement_results")
            .field("coverage_required", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("achievement_results")
            .deleteField("coverage_percent")
            .update()
        try await database.schema("achievement_results")
            .deleteField("coverage_required")
            .update()
    }
}

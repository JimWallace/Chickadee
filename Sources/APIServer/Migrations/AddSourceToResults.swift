// APIServer/Migrations/AddSourceToResults.swift
//
// Adds a `source` column to the results table to distinguish browser-side
// preliminary results from authoritative worker results.
//
//   source = "worker"  — result reported by a worker (official grade)
//   source = "browser" — result reported by the student's browser (preview)

import Fluent

struct AddSourceToResults: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("results")
            .field("source", .string)   // nullable on existing rows; treated as "worker"
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("results")
            .deleteField("source")
            .update()
    }
}

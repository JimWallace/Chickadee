// APIServer/Migrations/CreateDatabaseProfile.swift
//
// The single-row store behind the admin Overview's Database card
// (`DatabaseProfileRecord`). The primary key makes the first insert
// first-wins, and the compare-and-set update reads by that key, so the table
// needs no other index. It holds one row for good, so it needs no reaper.
// Fluent's `.json` is `jsonb` on Postgres.

import Fluent

struct CreateDatabaseProfile: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DatabaseProfileRecord.schema)
            .field("key", .string, .identifier(auto: false))
            .field("fingerprint_json", .json, .required)
            .field("previous_json", .json)
            .field("since", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DatabaseProfileRecord.schema).delete()
    }
}

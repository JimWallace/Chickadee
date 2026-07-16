// APIServer/Migrations/CreateResultCollections.swift
//
// Moves `results.collection_json` to the `result_collections` side table
// (#1173). The blob dominated the row width (up to the 6 MB collection
// budget) and the table's on-disk footprint, so every full-row load — the
// preferred-result maps, per-student history, sweeps — dragged megabytes it
// never read. After this migration the hot `results` row carries only
// scalars; the blob is fetched explicitly by the few readers that need it.
//
// Shipped standalone (not folded into CreateResults) because production
// databases already applied CreateResults with the column. Fresh deploys run
// CreateResults (which still creates `collection_json`) and then this
// migration relocates it — the same convention as
// ChangeAssignmentIsOpenToVisibility.
//
// The backfill is chunked raw SQL (`INSERT … SELECT … LIMIT`): the copy
// happens entirely inside the database, so a production table with tens of
// thousands of multi-MB blobs never streams through Swift, and each pass is
// bounded. `NOT EXISTS` keys each pass off what's already copied, so the
// loop is also re-entrant if a previous attempt died midway.

import Fluent
import SQLKit

struct CreateResultCollections: ChickadeeMigration {
    /// Rows copied per backfill pass. Internal so the migration test can
    /// prove multi-pass behaviour against a seeded multi-thousand-row table.
    static let backfillChunkSize = 1_000

    func prepare(on database: Database) async throws {
        try await database.schema("result_collections")
            .field(
                "result_id",
                .string,
                .identifier(auto: false),
                .references("results", "id", onDelete: .cascade)
            )
            .field("collection_json", .string, .required)
            .create()

        try await Self.backfill(on: database)

        try await database.schema("results")
            .deleteField("collection_json")
            .update()
    }

    /// Copies every not-yet-copied blob into the side table, one bounded
    /// chunk at a time, until none remain.
    static func backfill(on database: Database, chunkSize: Int = backfillChunkSize) async throws {
        guard let sql = database as? SQLDatabase else { return }
        struct CountRow: Decodable { let remaining: Int }
        while true {
            let row = try await sql.raw(
                """
                SELECT COUNT(*) AS remaining FROM results r
                WHERE NOT EXISTS (
                    SELECT 1 FROM result_collections rc WHERE rc.result_id = r.id
                )
                """
            ).first(decoding: CountRow.self)
            guard let remaining = row?.remaining, remaining > 0 else { return }

            try await sql.raw(
                """
                INSERT INTO result_collections (result_id, collection_json)
                SELECT r.id, r.collection_json FROM results r
                WHERE NOT EXISTS (
                    SELECT 1 FROM result_collections rc WHERE rc.result_id = r.id
                )
                LIMIT \(bind: chunkSize)
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "ALTER TABLE results ADD COLUMN collection_json TEXT NOT NULL DEFAULT '{}'"
            ).run()
            try await sql.raw(
                """
                UPDATE results SET collection_json = COALESCE(
                    (SELECT rc.collection_json FROM result_collections rc
                     WHERE rc.result_id = results.id),
                    '{}'
                )
                """
            ).run()
        } else {
            try await database.schema("results").field("collection_json", .string).update()
        }
        try await database.schema("result_collections").delete()
    }
}

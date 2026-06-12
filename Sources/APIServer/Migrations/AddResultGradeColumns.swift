import Fluent
import SQLKit

/// Denormalizes the grade out of `results.collection_json` (June 2026 audit,
/// finding P1.1). Adds `earned_points` / `total_points` / `pass_count` /
/// `total_tests` columns and backfills them from the JSON blob in one
/// statement, so the student dashboard, instructor roster, grades CSV export,
/// and the achievement / BrightSpace sweeps can read a grade as a column
/// instead of decoding the full result blob per row.
///
/// `collection_json` remains the source of truth for everything else; new rows
/// get the columns stamped by `APIResult.populateGradeFields()` at write time.
struct AddResultGradeColumns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One ADD COLUMN per statement — SQLite rejects a multi-column ALTER.
        try await database.schema("results").field("earned_points", .double).update()
        try await database.schema("results").field("total_points", .double).update()
        try await database.schema("results").field("pass_count", .int).update()
        try await database.schema("results").field("total_tests", .int).update()

        guard let sql = database as? SQLDatabase else { return }

        // Backfill from the blob. Every row was written by JSONEncoder so the
        // JSON is well-formed; the LIKE guard skips anything that isn't an
        // object (defensive — a malformed row would otherwise abort startup).
        if sql.dialect.name == "postgresql" {
            try await sql.raw(
                """
                UPDATE results SET
                    earned_points = (collection_json::jsonb->>'earnedPoints')::double precision,
                    total_points  = (collection_json::jsonb->>'totalPoints')::double precision,
                    pass_count    = (collection_json::jsonb->>'passCount')::integer,
                    total_tests   = (collection_json::jsonb->>'totalTests')::integer
                WHERE collection_json LIKE '{%'
                """
            ).run()
        } else {
            try await sql.raw(
                """
                UPDATE results SET
                    earned_points = json_extract(collection_json, '$.earnedPoints'),
                    total_points  = json_extract(collection_json, '$.totalPoints'),
                    pass_count    = json_extract(collection_json, '$.passCount'),
                    total_tests   = json_extract(collection_json, '$.totalTests')
                WHERE collection_json LIKE '{%'
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("results").deleteField("total_tests").update()
        try await database.schema("results").deleteField("pass_count").update()
        try await database.schema("results").deleteField("total_points").update()
        try await database.schema("results").deleteField("earned_points").update()
    }
}

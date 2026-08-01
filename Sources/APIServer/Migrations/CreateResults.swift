// APIServer/Migrations/CreateResults.swift

import Fluent

struct CreateResults: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("results")
            .field("id", .string, .identifier(auto: false))
            .field(
                "submission_id",
                .string,
                .required,
                .references("submissions", "id", onDelete: .cascade)
            )
            .field("collection_json", .string, .required)
            .field("source", .string, .required)
            .field("received_at", .datetime)
            // Folded from AddBrightSpaceSyncFields.  Sync state per-result so
            // a regrade can re-flag a previously-synced result as pending
            // without losing the original sync timestamp.
            .field("brightspace_sync_pending", .bool)
            .field("brightspace_pending_since", .datetime)
            .field("brightspace_synced_at", .datetime)
            .field("brightspace_sync_error", .string)
            // Folded from AddResultGradeColumns (June 2026 audit, P1.1): the
            // grade denormalized out of the collection blob so list pages, the
            // CSV export, and the sweeps read columns instead of decoding JSON
            // per row. New rows are stamped by APIResult.populateGradeFields()
            // at write time; the historical migration's one-time blob backfill
            // is a no-op on an empty fresh table and was dropped in the fold.
            .field("earned_points", .double)
            .field("total_points", .double)
            .field("pass_count", .int)
            .field("total_tests", .int)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("results").delete()
    }
}

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
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("results").delete()
    }
}

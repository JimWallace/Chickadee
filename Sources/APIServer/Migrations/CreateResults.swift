// APIServer/Migrations/CreateResults.swift

import Fluent

struct CreateResults: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("results")
            .field("id",              .string, .identifier(auto: false))
            .field(
                "submission_id",
                .string,
                .required,
                .references("submissions", "id", onDelete: .cascade)
            )
            .field("collection_json", .string, .required)
            .field("source",          .string, .required)
            .field("received_at",     .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("results").delete()
    }
}

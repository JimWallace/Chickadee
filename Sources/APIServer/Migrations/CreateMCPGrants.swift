// APIServer/Migrations/CreateMCPGrants.swift
//
// Durable OAuth grants (refresh-token backed) for the MCP authorization server.
//
// The second (0.5.0) consolidation round folded in
// AddPreviousRefreshTokenHashToGrants (the `previous_refresh_token_hash`
// column for rotation theft detection) and
// AddGrantPreviousRefreshTokenHashIndex (its hot-path index).

import Fluent
import SQLKit

struct CreateMCPGrants: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_grants")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("client_id", .string, .required)
            .field("scope", .string, .required)
            .field("refresh_token_hash", .string, .required)
            // Folded from AddPreviousRefreshTokenHashToGrants: the
            // just-rotated-away refresh-token hash, so a replay of an
            // already-rotated token can be detected and the grant revoked.
            .field("previous_refresh_token_hash", .string)
            .field("expires_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "refresh_token_hash")
            .create()

        // Folded from AddGrantPreviousRefreshTokenHashIndex: the refresh
        // rotation theft-detection lookup and the POST /oauth/revoke OR-filter
        // both query this column on every refresh / revoke.
        // (`refresh_token_hash` is already indexed by its UNIQUE constraint.)
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_oauth_grants_previous_refresh_token_hash "
                    + "ON oauth_grants(previous_refresh_token_hash)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        // Dropping the table drops its indexes on both backends.
        try await database.schema("oauth_grants").delete()
    }
}

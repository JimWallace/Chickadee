// APIServer/Migrations/AddPreviousRefreshTokenHashToGrants.swift
//
// Adds the previous (just-rotated-away) refresh-token hash to oauth_grants so a
// replay of an already-rotated refresh token can be detected and the grant
// revoked (theft response).

import Fluent

struct AddPreviousRefreshTokenHashToGrants: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_grants")
            .field("previous_refresh_token_hash", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_grants")
            .deleteField("previous_refresh_token_hash")
            .update()
    }
}

// APIServer/Migrations/CreateMCPGrants.swift
//
// Durable OAuth grants (refresh-token backed) for the MCP authorization server.

import Fluent

struct CreateMCPGrants: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_grants")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("client_id", .string, .required)
            .field("scope", .string, .required)
            .field("refresh_token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .field("revoked", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "refresh_token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_grants").delete()
    }
}

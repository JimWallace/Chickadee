// APIServer/Migrations/CreateMCPOAuthClients.swift
//
// Registered OAuth clients (agents) for the MCP authorization server.

import Fluent

struct CreateMCPOAuthClients: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_clients")
            .id()
            .field("client_id", .string, .required)
            .field("name", .string, .required)
            .field("redirect_uris", .string, .required)
            .field("is_public", .bool, .required)
            .field("created_by", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime, .required)
            .unique(on: "client_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_clients").delete()
    }
}

// APIServer/Migrations/CreateMCPAuthorizationCodes.swift
//
// Short-lived PKCE authorization codes for the MCP authorization server.

import Fluent

struct CreateMCPAuthorizationCodes: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_authorization_codes")
            .id()
            .field("code_hash", .string, .required)
            .field("client_id", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("redirect_uri", .string, .required)
            .field("code_challenge", .string, .required)
            .field("code_challenge_method", .string, .required)
            .field("scope", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "code_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_authorization_codes").delete()
    }
}

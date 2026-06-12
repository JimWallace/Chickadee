// APIServer/Migrations/CreateMCPConsentRequests.swift
//
// Short-lived, single-use consent requests for the browser OAuth flow.  Lets
// `POST /oauth/authorize` work without a session cookie (Safari/ITP drops it on
// the cross-site submit) by carrying the consenting user + frozen OAuth params
// server-side, keyed by an unguessable token hash.

import Fluent

struct CreateMCPConsentRequests: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oauth_consent_requests")
            .id()
            .field("token_hash", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("client_id", .string, .required)
            .field("redirect_uri", .string, .required)
            .field("scope", .string, .required)
            .field("state", .string, .required)
            .field("code_challenge", .string, .required)
            .field("code_challenge_method", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oauth_consent_requests").delete()
    }
}

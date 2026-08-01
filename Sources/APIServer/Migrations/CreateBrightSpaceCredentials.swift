// APIServer/Migrations/CreateBrightSpaceCredentials.swift
//
// Single-row store for the authorize-captured D2L Valence user key (see
// APIBrightSpaceCredential / BrightSpaceCredentialStore).

import Fluent

struct CreateBrightSpaceCredentials: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("brightspace_credentials")
            .id()
            .field("valence_user_id", .string, .required)
            .field("valence_user_key", .string, .required)
            .field("identity_name", .string)
            .field("captured_by_user_id", .uuid)
            // Folded from AddBrightSpaceCredentialUserID: the instructor a
            // stored Valence user key belongs to. NULL = the deployment-wide
            // (admin/env) service identity. Bare uuid (no FK), matching
            // captured_by_user_id.
            .field("user_id", .uuid)
            .field("captured_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("brightspace_credentials").delete()
    }
}

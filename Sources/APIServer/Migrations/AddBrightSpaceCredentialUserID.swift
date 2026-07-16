// APIServer/Migrations/AddBrightSpaceCredentialUserID.swift
//
// Adds `brightspace_credentials.user_id`: the instructor a stored Valence user
// key belongs to. NULL = the deployment-wide (admin/env) service identity — the
// original single-row behaviour, kept as a fallback. Captured per-instructor via
// the "Connect my LEARN account" flow.
//
// Registered after CreateBrightSpaceCredentials (the table must exist first).
// Bare uuid (no FK), matching the existing captured_by_user_id column.

import Fluent

struct AddBrightSpaceCredentialUserID: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("brightspace_credentials")
            .field("user_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("brightspace_credentials")
            .deleteField("user_id")
            .update()
    }
}

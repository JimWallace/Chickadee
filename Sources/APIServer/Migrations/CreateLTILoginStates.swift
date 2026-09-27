// APIServer/Migrations/CreateLTILoginStates.swift
//
// LTI 1.3 logins in flight (docs/lti-1-3.md slice 2). New table; its FK
// targets `lti_platforms`, so it must follow CreateLTIPlatforms. Deleting a
// platform deletes its pending logins.

import Fluent

struct CreateLTILoginStates: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APILTILoginState.schema)
            .id()
            .field("state_hash", .string, .required)
            .field("nonce", .string, .required)
            .field("platform_id", .uuid, .required, .references("lti_platforms", "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "state_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTILoginState.schema).delete()
    }
}

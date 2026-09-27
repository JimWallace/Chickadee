// APIServer/Migrations/CreateLTIIdentities.swift
//
// LTI subject → Chickadee account links (docs/lti-1-3.md "Identity"). New
// table; it must follow CreateLTIPlatforms and CreateUsers. One row per
// (platform, subject), so a subject can never resolve to two accounts.

import Fluent

struct CreateLTIIdentities: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APILTIIdentity.schema)
            .id()
            .field("platform_id", .uuid, .required, .references("lti_platforms", "id", onDelete: .cascade))
            .field("subject", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "platform_id", "subject")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTIIdentity.schema).delete()
    }
}

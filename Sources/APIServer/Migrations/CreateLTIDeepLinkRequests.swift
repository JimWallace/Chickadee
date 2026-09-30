// APIServer/Migrations/CreateLTIDeepLinkRequests.swift
//
// Deep-linking requests waiting for a choice (docs/lti-1-3.md "Deep
// Linking"). New table; its FKs target `lti_platforms`, `courses` and
// `users`, so it must follow them. Deleting any of the three deletes its
// waiting requests.

import Fluent

struct CreateLTIDeepLinkRequests: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APILTIDeepLinkRequest.schema)
            .id()
            .field("ticket_hash", .string, .required)
            .field("platform_id", .uuid, .required, .references("lti_platforms", "id", onDelete: .cascade))
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("return_url", .string, .required)
            .field("data", .string)
            .field("deployment_id", .string, .required)
            .field("accept_multiple", .bool, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed", .bool, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "ticket_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTIDeepLinkRequest.schema).delete()
    }
}

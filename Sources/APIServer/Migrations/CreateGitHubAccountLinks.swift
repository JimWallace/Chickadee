// APIServer/Migrations/CreateGitHubAccountLinks.swift
//
// Linked GitHub accounts (docs/github-submissions.md slice 2). New table; it
// must follow CreateUsers. Both columns are unique: one link per Chickadee
// user, and one Chickadee user per GitHub account.

import Fluent

struct CreateGitHubAccountLinks: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APIGitHubAccountLink.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("github_user_id", .int64, .required)
            .field("github_login", .string, .required)
            .field("linked_at", .datetime, .required)
            .unique(on: "user_id")
            .unique(on: "github_user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIGitHubAccountLink.schema).delete()
    }
}

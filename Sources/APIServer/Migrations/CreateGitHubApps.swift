// APIServer/Migrations/CreateGitHubApps.swift
//
// The registered GitHub App (docs/github-submissions.md slice 1). New table, no
// foreign keys, so no ordering constraint. `app_id` is unique, which is as far
// as the database can go toward "at most one row"; the admin route refuses a
// second registration.

import Fluent

struct CreateGitHubApps: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APIGitHubApp.schema)
            .id()
            .field("app_id", .int, .required)
            .field("slug", .string, .required)
            .field("name", .string, .required)
            .field("client_id", .string, .required)
            .field("html_url", .string, .required)
            .field("owner_login", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "app_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIGitHubApp.schema).delete()
    }
}

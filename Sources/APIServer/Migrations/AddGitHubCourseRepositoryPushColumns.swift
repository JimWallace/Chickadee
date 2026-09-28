// APIServer/Migrations/AddGitHubCourseRepositoryPushColumns.swift
//
// The last push to a course repository, from a webhook
// (docs/github-submissions.md slice 5). Nil on every existing row.

import Fluent

struct AddGitHubCourseRepositoryPushColumns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One column per update: SQLite alters one column per statement.
        try await database.schema(APIGitHubCourseRepository.schema).field("last_pushed_at", .datetime).update()
        try await database.schema(APIGitHubCourseRepository.schema).field("last_push_sha", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIGitHubCourseRepository.schema).deleteField("last_push_sha").update()
        try await database.schema(APIGitHubCourseRepository.schema).deleteField("last_pushed_at").update()
    }
}

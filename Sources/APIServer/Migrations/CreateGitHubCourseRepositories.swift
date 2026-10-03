// APIServer/Migrations/CreateGitHubCourseRepositories.swift
//
// Course repositories (docs/github-submissions.md slice 4): the organization
// bound to a course, an assignment's template, and the repository made for
// each student. New tables only; empty tables change nothing.
//
// The last-push columns were folded in from
// AddGitHubCourseRepositoryPushColumns in the fourth round (#1806).

import Fluent

struct CreateGitHubCourseRepositories: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APIGitHubCourseOrganization.schema)
            .id()
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("installation_id", .int64, .required)
            .field("org_id", .int64, .required)
            .field("org_login", .string, .required)
            .field("bound_at", .datetime, .required)
            .unique(on: "course_id")
            .create()
        try await database.schema(APIGitHubAssignmentTemplate.schema)
            .id()
            .field(
                "test_setup_id", .string, .required, .references("test_setups", "id", onDelete: .cascade)
            )
            .field("template_repo_id", .int64, .required)
            .field("template_full_name", .string, .required)
            .field("set_at", .datetime, .required)
            .unique(on: "test_setup_id")
            .create()
        try await database.schema(APIGitHubCourseRepository.schema)
            .id()
            .field(
                "test_setup_id", .string, .required, .references("test_setups", "id", onDelete: .cascade)
            )
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("repo_id", .int64, .required)
            .field("repo_full_name", .string, .required)
            .field("invited", .bool, .required)
            .field("archived_at", .datetime)
            .field("created_at", .datetime, .required)
            // The last push to the repository, from a webhook
            // (docs/github-submissions.md slice 5). nil = no push seen.
            .field("last_pushed_at", .datetime)
            .field("last_push_sha", .string)
            .unique(on: "test_setup_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIGitHubCourseRepository.schema).delete()
        try await database.schema(APIGitHubAssignmentTemplate.schema).delete()
        try await database.schema(APIGitHubCourseOrganization.schema).delete()
    }
}

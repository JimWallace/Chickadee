// APIServer/Migrations/AddGitHubCourseRepositoryInvitedUser.swift
//
// `github_course_repositories.invited_github_user_id`: the numeric ID of the
// GitHub account the course repository's invitation went to. A student who
// links another account keeps the repository, so without the ID the server
// could not tell that the collaborator is no longer the linked account, and a
// mistaken link left a classmate with write access (#2208). Optional: rows
// made before it record no ID.

import Fluent

struct AddGitHubCourseRepositoryInvitedUser: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APIGitHubCourseRepository.schema)
            .field("invited_github_user_id", .int64)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIGitHubCourseRepository.schema)
            .deleteField("invited_github_user_id")
            .update()
    }
}

// APIServer/Models/APIGitHubCourseRepository.swift
//
// The course repository made for one student on one assignment
// (docs/github-submissions.md slice 4). The repository ID is the identity, so
// a rename on GitHub does not break the mapping.

import Fluent
import Vapor

final class APIGitHubCourseRepository: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "github_course_repositories"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "repo_id")
    var repoID: Int64

    /// `owner/name` when it was made, for display.
    @Field(key: "repo_full_name")
    var repoFullName: String

    /// False when the repository exists but the invitation failed, so the
    /// student can ask for it again.
    @Field(key: "invited")
    var invited: Bool

    /// Set when the repository was archived at the end of term.
    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(testSetupID: String, userID: UUID, repoID: Int64, repoFullName: String, invited: Bool) {
        self.testSetupID = testSetupID
        self.userID = userID
        self.repoID = repoID
        self.repoFullName = repoFullName
        self.invited = invited
    }
}

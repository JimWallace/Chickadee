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

    /// The numeric ID of the GitHub account the invitation went to. When it
    /// is not the account the student has linked now, the collaborator is
    /// moved to the linked account (#2208). Nil on rows made before it was
    /// recorded.
    @OptionalField(key: "invited_github_user_id")
    var invitedGitHubUserID: Int64?

    /// Set when the repository was archived at the end of term.
    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    /// When a webhook last reported a push (slice 5), by the server's clock.
    /// Display only: a push never starts a grading job.
    @OptionalField(key: "last_pushed_at")
    var lastPushedAt: Date?

    /// The commit that push left the default branch at, or any branch.
    @OptionalField(key: "last_push_sha")
    var lastPushSHA: String?

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

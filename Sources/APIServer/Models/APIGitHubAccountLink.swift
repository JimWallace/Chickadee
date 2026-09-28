// APIServer/Models/APIGitHubAccountLink.swift
//
// A Chickadee account's linked GitHub account (docs/github-submissions.md
// "Linking an account"). One row per Chickadee user, and one per GitHub
// account: a GitHub account can not link to two Chickadee users.
//
// The numeric GitHub user ID is the identity. The login is for display only,
// because a GitHub user can rename their account. No token is stored: the
// link flow reads the user and discards the token.

import Fluent
import Vapor

final class APIGitHubAccountLink: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "github_account_links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// GitHub's numeric user ID. Stable across renames.
    @Field(key: "github_user_id")
    var githubUserID: Int64

    /// The GitHub login when the account was linked, for display.
    @Field(key: "github_login")
    var githubLogin: String

    @Timestamp(key: "linked_at", on: .create)
    var linkedAt: Date?

    init() {}

    init(userID: UUID, githubUserID: Int64, githubLogin: String) {
        self.userID = userID
        self.githubUserID = githubUserID
        self.githubLogin = githubLogin
    }
}

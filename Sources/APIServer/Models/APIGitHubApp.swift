// APIServer/Models/APIGitHubApp.swift
//
// The registered GitHub App (docs/github-submissions.md "App credentials").
// The table holds at most one row; no row means GitHub submission is off.
//
// Nothing here is secret: the App ID, slug and client ID are identifiers that
// GitHub shows publicly. The private key, client secret and webhook secret
// live in `.github-app-secrets` (GitHubAppSecrets).

import Fluent
import Vapor

final class APIGitHubApp: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "github_apps"

    @ID(key: .id)
    var id: UUID?

    /// GitHub's numeric App ID. Installation-token requests are signed for it.
    @Field(key: "app_id")
    var appID: Int

    /// The App's URL name, e.g. `chickadee-courses-example-edu`.
    @Field(key: "slug")
    var slug: String

    /// The App's display name on GitHub.
    @Field(key: "name")
    var name: String

    /// The OAuth client ID that account linking uses (slice 2).
    @Field(key: "client_id")
    var clientID: String

    /// The App's page on GitHub, where an admin changes or deletes it.
    @Field(key: "html_url")
    var htmlURL: String

    /// The account or organization that owns the App.
    @OptionalField(key: "owner_login")
    var ownerLogin: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(conversion: GitHubManifestConversion) {
        appID = conversion.id
        slug = conversion.slug
        name = conversion.name
        clientID = conversion.clientID
        htmlURL = conversion.htmlURL
        ownerLogin = conversion.owner?.login
    }
}

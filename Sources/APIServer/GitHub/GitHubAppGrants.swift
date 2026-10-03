// APIServer/GitHub/GitHubAppGrants.swift
//
// What the GitHub App may do, read live from GitHub (#1776).
//
// The admin chooses three options when creating the App (course repositories,
// push events, commit statuses), and anyone with access to the App's settings
// on GitHub can change them later. An organization owner must also accept a
// changed permission before the App's installation there gets it. So the
// choice is not stored at registration: the admin page reads the App
// (`GET /app`) and the course page reads the organization's installation
// (`GET /app/installations/{id}`) when they render, and each says which of
// the three the App lacks. Without this, each missing option failed in its
// own silent way: a GitHub error when a student made a repository, pushes
// that never arrived, statuses that were logged and dropped.

import Vapor

struct GitHubAppGrants: Sendable, Equatable {
    /// The options an admin chooses when creating the App.
    enum Capability: String, CaseIterable, Sendable {
        case courseRepositories, pushEvents, commitStatuses

        var label: String {
            switch self {
            case .courseRepositories: "Course repositories"
            case .pushEvents: "Push events"
            case .commitStatuses: "Commit statuses"
            }
        }
    }

    /// Permission name to access level ("read", "write" or "admin").
    let permissions: [String: String]
    /// The webhook events the App or installation receives.
    let events: [String]

    /// True when the grants cover `capability`. The permissions come from the
    /// manifest's own constants, so the check and the request cannot differ.
    func allows(_ capability: Capability) -> Bool {
        switch capability {
        case .courseRepositories: covers(GitHubAppManifest.courseRepositoryPermissions)
        case .pushEvents: events.contains("push")
        case .commitStatuses: covers(GitHubAppManifest.commitStatusPermissions)
        }
    }

    /// The capabilities the grants do not cover, in display order.
    var missing: [Capability] {
        Capability.allCases.filter { !allows($0) }
    }

    /// True when every permission in `required` is granted at its level or
    /// higher. "write" covers "read", and "admin" covers both.
    private func covers(_ required: [String: String]) -> Bool {
        let rank = ["read": 1, "write": 2, "admin": 3]
        return required.allSatisfy { name, level in
            (rank[permissions[name] ?? ""] ?? 0) >= (rank[level] ?? Int.max)
        }
    }
}

extension GitHubAppGrants {
    /// What the App asks for now, or nil when GitHub cannot be asked or does
    /// not answer. The reason is logged; the page says only that it could not
    /// read them.
    static func ofApp(_ app: APIGitHubApp, secrets: GitHubAppSecrets, req: Request) async -> GitHubAppGrants? {
        await read(app: app, secrets: secrets, req: req) { client, jwt in try await client.appGrants(jwt) }
    }

    /// What the App's installation `installationID` was granted, or nil when
    /// GitHub cannot be asked or does not answer.
    static func ofInstallation(
        _ installationID: Int64, app: APIGitHubApp, secrets: GitHubAppSecrets, req: Request
    ) async -> GitHubAppGrants? {
        await read(app: app, secrets: secrets, req: req) { client, jwt in
            try await client.installationGrants(jwt, installationID)
        }
    }

    /// Signs the App JWT and runs `body` with it.
    private static func read(
        app: APIGitHubApp, secrets: GitHubAppSecrets, req: Request,
        _ body: (GitHubRepoClient, String) async throws -> GitHubAppGrants
    ) async -> GitHubAppGrants? {
        do {
            let jwt = try await GitHubAppJWT.sign(appID: app.appID, privateKeyPEM: secrets.privateKeyPEM)
            return try await body(req.application.githubRepoClient, jwt)
        } catch {
            req.logger.warning("GitHub App permissions not read", metadata: ["error": "\(error)"])
            return nil
        }
    }
}

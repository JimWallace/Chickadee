// APIServer/Routes/GitHubWebhookRoutes.swift
//
//   POST /github/webhook   → a GitHub event delivery (docs/github-submissions.md slice 5)
//
// Display only. A push records when the course repository was last pushed and
// to which commit, so staff can see it; it never starts a grading job, uses no
// attempt and takes no runner slot. An `installation` delivery that removes or
// suspends the App on an account drops that account's cached token (#1768).
// Every other event is accepted and ignored.
//
// No session and no CSRF token: GitHub is the caller, and the signature over
// the raw body (`X-Hub-Signature-256`, HMAC-SHA256 under the App's webhook
// secret) is the only authentication. 404 while no App with a webhook secret is
// registered, so the route answers nothing a deployment has not turned on.
//
// The push payload also carries commit messages, author names and email
// addresses and the pusher's login. None of it is stored or logged: the route
// decodes the repository ID and the new head commit, and nothing else.

import Fluent
import Foundation
import Vapor

struct GitHubWebhookRoutes: RouteCollection {
    /// GitHub caps a delivery at 25 MB; a push that large is not worth reading
    /// for two fields, so GitHub records it as a failed delivery.
    static let maxBodySize: ByteCount = "5mb"

    func boot(routes: RoutesBuilder) throws {
        routes.on(.POST, "github", "webhook", body: .collect(maxSize: Self.maxBodySize), use: receive)
    }

    private struct PushEvent: Decodable {
        struct Repository: Decodable { let id: Int64 }
        let repository: Repository
        let after: String
        let deleted: Bool?
    }

    private struct InstallationAccount: Decodable { let id: Int64 }
    private struct Installation: Decodable { let account: InstallationAccount }
    private struct InstallationEvent: Decodable {
        let action: String
        let installation: Installation
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        guard
            try await APIGitHubApp.query(on: req.db).count() > 0,
            let secret = (try? GitHubAppSecrets.load(path: req.application.githubAppSecretsFilePath))?.webhookSecret
        else { throw Abort(.notFound) }
        let body = req.body.data.map { Data(buffer: $0) } ?? Data()
        guard
            GitHubWebhookSignature.isValid(
                body: body, header: req.headers.first(name: "X-Hub-Signature-256"), secret: secret)
        else { throw Abort(.unauthorized) }

        let event = req.headers.first(name: "X-GitHub-Event")
        if event == "installation" {
            // The App was removed from an account, or suspended there: drop
            // its cached token now rather than serving it for up to an hour
            // and reading the refusal as "GitHub did not respond" (#1768).
            if let delivery = try? JSONDecoder().decode(InstallationEvent.self, from: body),
                delivery.action == "deleted" || delivery.action == "suspend"
            {
                await req.application.githubInstallationTokens.remove(account: delivery.installation.account.id)
            }
            return .noContent
        }
        guard event == "push" else { return .noContent }
        guard let push = try? JSONDecoder().decode(PushEvent.self, from: body) else {
            throw Abort(.badRequest)
        }
        // A deleted branch leaves no commit to show.
        let sha = push.after.lowercased()
        guard push.deleted != true, GitHubCommitSHA.isWellFormed(sha), sha != String(repeating: "0", count: 40)
        else { return .noContent }
        try await APIGitHubCourseRepository.query(on: req.db)
            .filter(\.$repoID == push.repository.id)
            .set(\.$lastPushedAt, to: Date())
            .set(\.$lastPushSHA, to: sha)
            .update()
        return .noContent
    }
}

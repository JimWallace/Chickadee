// APIServer/Routes/Web/GitHubAccountLinkRoutes.swift
//
// Linking a GitHub account to a Chickadee account (docs/github-submissions.md
// slice 2). Any signed-in user; every route is inert until an admin registers
// the GitHub App.
//
//   POST /account/github/link    → redirect to GitHub to authorize the App
//   GET  /github/link/callback   → GitHub returns here; store the link
//   POST /account/github/unlink  → delete the link
//
// The callback URL is the one the slice-1 manifest registered with GitHub.
// The flow keeps GitHub's numeric user ID and login, and revokes the user
// token at once: nothing that can act on the student's GitHub account stays
// on the server.

import Fluent
import Foundation
import Vapor

struct GitHubAccountLinkRoutes: RouteCollection {
    static let stateKey = "githubLinkState"
    static let verifierKey = "githubLinkVerifier"

    /// Post-redirect notices on the account page, as keys so a query string
    /// cannot put arbitrary text on the page.
    enum Notice: String {
        case linked, unlinked

        var message: String {
            switch self {
            case .linked: "GitHub account linked."
            case .unlinked: "GitHub account unlinked."
            }
        }
    }

    func boot(routes: RoutesBuilder) throws {
        routes.post("account", "github", "link", use: startLink)
        routes.get("github", "link", "callback", use: callback)
        routes.post("account", "github", "unlink", use: unlink)
    }

    // MARK: - POST /account/github/link

    @Sendable
    func startLink(req: Request) async throws -> Response {
        _ = try req.auth.require(APIUser.self)
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let redirectURI = GitHubUserAuthorization.redirectURI(
                publicBaseURL: req.application.securityConfiguration.publicBaseURL)
        else {
            return Self.redirectToAccount(req, error: .unavailable)
        }
        let authorization = GitHubUserAuthorization.make()
        req.session.data[Self.stateKey] = authorization.state
        req.session.data[Self.verifierKey] = authorization.codeVerifier
        return req.redirect(to: authorization.authorizeURL(clientID: app.clientID, redirectURI: redirectURI))
    }

    // MARK: - GET /github/link/callback

    @Sendable
    func callback(req: Request) async throws -> Response {
        // GitHub accepts one user-authorization callback URL, so binding a
        // course organization (slice 4) returns here too.
        if GitHubCourseRoutes.isBinding(req) {
            return try await GitHubCourseRoutes.completeBinding(req: req)
        }
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let expectedState = req.session.data[Self.stateKey]
        let verifier = req.session.data[Self.verifierKey]
        req.session.data[Self.stateKey] = nil
        req.session.data[Self.verifierKey] = nil
        do {
            guard let expectedState, let verifier, req.query[String.self, at: "state"] == expectedState else {
                throw GitHubLinkError.stateMismatch
            }
            guard let code = req.query[String.self, at: "code"], GitHubManifestCode.isWellFormed(code) else {
                throw GitHubLinkError.cancelled
            }
            let githubUser = try await Self.fetchGitHubUser(code: code, verifier: verifier, req: req)
            try await Self.saveLink(userID: userID, githubUser: githubUser, on: req.db)
            await AuditLogger.record(
                action: .githubAccountLinked, targetType: .user, targetID: userID.uuidString,
                metadata: ["github_user_id": String(githubUser.id), "github_login": githubUser.login], on: req)
            return req.redirect(to: "/account?github=\(Notice.linked.rawValue)")
        } catch let error as GitHubLinkError {
            return Self.redirectToAccount(req, error: error)
        }
    }

    // MARK: - POST /account/github/unlink

    @Sendable
    func unlink(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        if let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first() {
            let githubUserID = String(link.githubUserID)
            try await link.delete(on: req.db)
            await AuditLogger.record(
                action: .githubAccountUnlinked, targetType: .user, targetID: userID.uuidString,
                metadata: ["github_user_id": githubUserID], on: req)
        }
        return req.redirect(to: "/account?github=\(Notice.unlinked.rawValue)")
    }

    // MARK: - Helpers

    /// Exchanges the code, reads the user, and revokes the token.
    private static func fetchGitHubUser(
        code: String, verifier: String, req: Request
    ) async throws -> GitHubUser {
        guard
            let (app, secrets) = try await GitHubAppRegistration.resolve(req: req),
            let redirectURI = GitHubUserAuthorization.redirectURI(
                publicBaseURL: req.application.securityConfiguration.publicBaseURL)
        else { throw GitHubLinkError.unavailable }

        let client = req.application.githubOAuthClient
        let token: String
        do {
            token = try await client.exchangeCode(
                GitHubCodeExchange(
                    clientID: app.clientID, clientSecret: secrets.clientSecret, code: code,
                    codeVerifier: verifier, redirectURI: redirectURI))
        } catch {
            req.logger.warning("GitHub account link exchange failed", metadata: ["error": "\(error)"])
            throw GitHubLinkError.exchangeFailed
        }
        // Revoked before the answer is read, so a failed read keeps no token.
        let lookup = await client.withRevokedUserToken(
            token, clientID: app.clientID, clientSecret: secrets.clientSecret, logger: req.logger
        ) { token in try await client.fetchUser(token) }
        switch lookup {
        case .success(let githubUser):
            return githubUser
        case .failure(let error):
            req.logger.warning("GitHub account link user read failed", metadata: ["error": "\(error)"])
            throw GitHubLinkError.exchangeFailed
        }
    }

    /// Creates or replaces this user's link. A GitHub account already linked to
    /// another user is refused.
    private static func saveLink(userID: UUID, githubUser: GitHubUser, on db: Database) async throws {
        if let other = try await APIGitHubAccountLink.query(on: db)
            .filter(\.$githubUserID == githubUser.id).first(), other.userID != userID
        {
            throw GitHubLinkError.linkedElsewhere
        }
        if let existing = try await APIGitHubAccountLink.query(on: db).filter(\.$userID == userID).first() {
            existing.githubUserID = githubUser.id
            existing.githubLogin = githubUser.login
            try await existing.save(on: db)
        } else {
            try await APIGitHubAccountLink(
                userID: userID, githubUserID: githubUser.id, githubLogin: githubUser.login
            ).save(on: db)
        }
    }

    private static func redirectToAccount(_ req: Request, error: GitHubLinkError) -> Response {
        req.redirect(to: "/account?githubError=\(error.rawValue)")
    }
}

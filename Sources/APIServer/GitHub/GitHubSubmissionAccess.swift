// APIServer/GitHub/GitHubSubmissionAccess.swift
//
// What the server needs to read a student's repositories
// (docs/github-submissions.md slice 3): the registered App, the student's
// linked account, and an installation token for that account. Every GitHub
// call the submit page makes goes through here, so the ownership rule and the
// error mapping are in one place.

import Fluent
import Foundation
import Vapor

struct GitHubSubmissionAccess: Sendable {
    let link: APIGitHubAccountLink
    let token: String
    let client: GitHubRepoClient

    /// The link's GitHub account ID, read once.
    var githubUserID: Int64 { link.githubUserID }

    /// Where a student installs the App on their own account.
    static func installURL(for app: APIGitHubApp) -> String {
        "https://github.com/apps/\(GitHubRepoClient.pathSegment(app.slug))/installations/new"
    }

    /// Resolves the App, the link and a token. Throws `GitHubSubmitError`.
    static func resolve(userID: UUID, req: Request) async throws -> GitHubSubmissionAccess {
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let secrets = try? GitHubAppSecrets.load(path: req.application.githubAppSecretsFilePath)
        else { throw GitHubSubmitError.unavailable }
        guard let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
        else { throw GitHubSubmitError.notLinked }

        let client = req.application.githubRepoClient
        let cache = req.application.githubInstallationTokens
        if let token = await cache.token(forAccount: link.githubUserID) {
            return GitHubSubmissionAccess(link: link, token: token, client: client)
        }
        let token = try await calling(req) {
            let jwt = try await GitHubAppJWT.sign(appID: app.appID, privateKeyPEM: secrets.privateKeyPEM)
            // The installation must be on the linked account itself: a login
            // that has since moved to another GitHub account fails here.
            guard let installation = try await client.findInstallation(jwt, link.githubLogin),
                installation.accountID == link.githubUserID
            else { throw GitHubSubmitError.notInstalled }
            return try await client.createInstallationToken(jwt, installation.id)
        }
        await cache.store(token, forAccount: link.githubUserID)
        return GitHubSubmissionAccess(link: link, token: token.token, client: client)
    }

    /// The granted repositories that the linked account owns, by name.
    func ownedRepositories(req: Request) async throws -> [GitHubRepository] {
        try await Self.calling(req) {
            try await client.repositories(token)
                .filter { $0.ownerID == githubUserID }
                .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        }
    }

    /// One repository, after the ownership check: the repository's owner must
    /// be the linked account. Without it, a student could submit a classmate's
    /// repository that the classmate granted to the App.
    func ownedRepository(id: Int64, req: Request) async throws -> GitHubRepository {
        let repository = try await Self.calling(req) { try await client.repository(token, id) }
        guard let repository else { throw GitHubSubmitError.repositoryNotFound }
        guard repository.ownerID == githubUserID else { throw GitHubSubmitError.notOwner }
        return repository
    }

    func branches(of repository: GitHubRepository, req: Request) async throws -> [String] {
        try await Self.calling(req) { try await client.branches(token, repository.fullName).sorted() }
    }

    /// The commit `ref` points to now. Resolved once; everything after uses the SHA.
    func commit(_ ref: String, in repository: GitHubRepository, req: Request) async throws -> GitHubCommit {
        let commit = try await Self.calling(req) { try await client.commit(token, repository.fullName, ref) }
        guard let commit else { throw GitHubSubmitError.commitNotFound }
        return commit
    }

    /// The gzipped tarball of `sha`, no larger than the tar cap allows.
    func tarball(of repository: GitHubRepository, sha: String, req: Request) async throws -> Data {
        try await Self.calling(req) {
            try await client.tarball(token, repository.fullName, sha, GitHubTarball.maxTarBytes)
        }
    }

    /// Runs a GitHub call. Any error that is not already a `GitHubSubmitError`
    /// is logged and reported as `githubFailed`, so the student sees one
    /// sentence and no transport detail. Tokens are never logged.
    private static func calling<T: Sendable>(
        _ req: Request, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as GitHubSubmitError {
            throw error
        } catch {
            req.logger.warning("GitHub call failed", metadata: ["error": "\(error)"])
            throw GitHubSubmitError.githubFailed
        }
    }
}

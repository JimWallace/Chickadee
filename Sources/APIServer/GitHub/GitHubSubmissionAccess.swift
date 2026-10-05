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
    /// The GitHub account the token's installation is on: the cache entry to
    /// drop when GitHub refuses the token (#1768).
    let tokenAccountID: Int64
    /// A fresh token for that account, once the cached one is dropped.
    let renewToken: @Sendable (Request) async throws -> String
    /// Set in course-repository mode (slice 4): the only repository this
    /// student may submit from, read with the course organization's token.
    /// Nil means the student submits from a repository they own (slice 3).
    var courseRepositoryID: Int64?

    /// The link's GitHub account ID, read once.
    var githubUserID: Int64 { link.githubUserID }

    /// Where a student installs the App on their own account.
    static func installURL(for app: APIGitHubApp) -> String {
        "https://github.com/apps/\(GitHubRepoClient.pathSegment(app.slug))/installations/new"
    }

    /// Resolves the App, the link and a token. Throws `GitHubSubmitError`.
    static func resolve(userID: UUID, req: Request) async throws -> GitHubSubmissionAccess {
        guard let (app, secrets) = try await GitHubAppRegistration.resolve(req: req) else {
            throw GitHubSubmitError.unavailable
        }
        guard let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
        else { throw GitHubSubmitError.notLinked }

        let client = req.application.githubRepoClient
        let accountID = link.githubUserID
        let login = link.githubLogin
        let renew: @Sendable (Request) async throws -> String = { req in
            try await installationToken(accountID: accountID, app: app, secrets: secrets, req: req) { jwt in
                // The installation must be on the linked account itself: a login
                // that has since moved to another GitHub account is not taken.
                if let installation = try await client.findInstallation(jwt, login),
                    installation.accountID == accountID
                {
                    return installation.id
                }
                // The stored login misses when the student renamed the
                // account: find the installation by the account's numeric ID,
                // and keep the login it carries now (#2206).
                guard let found = try await client.installationByAccountID(jwt, accountID) else {
                    throw GitHubSubmitError.notInstalled
                }
                if found.accountLogin != link.githubLogin {
                    link.githubLogin = found.accountLogin
                    try await link.save(on: req.db)
                }
                return found.installationID
            }
        }
        let token = try await renew(req)
        return GitHubSubmissionAccess(
            link: link, token: token, client: client, tokenAccountID: accountID, renewToken: renew)
    }

    /// Course-repository mode (slice 4): the student's own course repository
    /// for `testSetupID`, read with the course organization's installation.
    /// The student needs a link, because their GitHub login is the
    /// collaborator on that repository.
    static func resolveCourseRepository(
        userID: UUID, testSetupID: String, courseID: UUID, req: Request
    ) async throws -> GitHubSubmissionAccess {
        guard let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
        else { throw GitHubSubmitError.notLinked }
        guard
            let repository = try await APIGitHubCourseRepository.query(on: req.db)
                .filter(\.$testSetupID == testSetupID).filter(\.$userID == userID).first()
        else { throw GitHubSubmitError.noCourseRepository }
        let organization = try await GitHubCourseAccess.resolve(courseID: courseID, req: req)
        return GitHubSubmissionAccess(
            link: link, token: organization.token, client: organization.client,
            tokenAccountID: organization.organization.orgID, renewToken: organization.renewToken,
            courseRepositoryID: repository.repoID)
    }

    /// An installation token for `accountID`, from the cache or new. `find`
    /// receives the App JWT and returns the installation to use.
    static func installationToken(
        accountID: Int64, app: APIGitHubApp, secrets: GitHubAppSecrets, req: Request,
        find: @escaping @Sendable (_ appJWT: String) async throws -> Int64
    ) async throws -> String {
        let cache = req.application.githubInstallationTokens
        if let token = await cache.token(forAccount: accountID) { return token }
        let client = req.application.githubRepoClient
        let token = try await calling(req) {
            let jwt = try await GitHubAppJWT.sign(appID: app.appID, privateKeyPEM: secrets.privateKeyPEM)
            return try await client.createInstallationToken(jwt, try await find(jwt))
        }
        await cache.store(token, forAccount: accountID)
        return token.token
    }

    /// The repositories this student may submit from: in course-repository
    /// mode the one made for them, else the granted repositories that the
    /// linked account owns, by name.
    func ownedRepositories(req: Request) async throws -> [GitHubRepository] {
        if let courseRepositoryID {
            return [try await ownedRepository(id: courseRepositoryID, req: req)]
        }
        return try await call(req) { token in
            try await client.repositories(token)
                .filter { $0.ownerID == githubUserID }
                .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        }
    }

    /// One repository, after the ownership check: the repository's owner must
    /// be the linked account. Without it, a student could submit a classmate's
    /// repository that the classmate granted to the App.
    /// In course-repository mode the rule is instead that `id` is the
    /// repository made for this student.
    func ownedRepository(id: Int64, req: Request) async throws -> GitHubRepository {
        if let courseRepositoryID, id != courseRepositoryID { throw GitHubSubmitError.notOwner }
        let repository = try await call(req) { token in try await client.repository(token, id) }
        guard let repository else { throw GitHubSubmitError.repositoryNotFound }
        guard courseRepositoryID != nil || repository.ownerID == githubUserID else {
            throw GitHubSubmitError.notOwner
        }
        return repository
    }

    func branches(of repository: GitHubRepository, req: Request) async throws -> [String] {
        try await call(req) { token in try await client.branches(token, repository.fullName).sorted() }
    }

    /// The commit `ref` points to now. Resolved once; everything after uses the SHA.
    func commit(_ ref: String, in repository: GitHubRepository, req: Request) async throws -> GitHubCommit {
        let commit = try await call(req) { token in try await client.commit(token, repository.fullName, ref) }
        guard let commit else { throw GitHubSubmitError.commitNotFound }
        return commit
    }

    /// The gzipped tarball of `sha`, no larger than the tar cap allows.
    func tarball(of repository: GitHubRepository, sha: String, req: Request) async throws -> Data {
        try await call(req) { token in
            try await client.tarball(token, repository.fullName, sha, GitHubTarball.maxTarBytes)
        }
    }

    /// Runs a GitHub call with the token, and once more with a fresh one when
    /// GitHub refuses it.
    func call<T: Sendable>(_ req: Request, _ body: (_ token: String) async throws -> T) async throws -> T {
        try await Self.calling(req, accountID: tokenAccountID, token: token, renew: renewToken, body)
    }

    /// `calling(_:_:)` with one retry on a refused token. A refusal means the
    /// token's installation was removed or re-made after the token was
    /// cached, so the cached entry is dropped and `renew` resolves a fresh
    /// one; a second refusal means the App is not installed (#1768).
    ///
    /// The call starts from the account's cached token when there is one,
    /// and from `token` only when there is not. `token` is the one the access
    /// was resolved with; after a refusal `renew` caches a fresh token, and
    /// without this every later call in the same request started from the
    /// refused one again (#2205).
    static func calling<T: Sendable>(
        _ req: Request, accountID: Int64, token: String,
        renew: @Sendable (Request) async throws -> String,
        _ body: (_ token: String) async throws -> T
    ) async throws -> T {
        let current = await req.application.githubInstallationTokens.token(forAccount: accountID) ?? token
        do {
            return try await calling(req) { try await body(current) }
        } catch GitHubSubmitError.tokenRejected {
            let cache = req.application.githubInstallationTokens
            await cache.remove(account: accountID)
            req.logger.info(
                "GitHub refused an installation token; resolving once more",
                metadata: ["account": "\(accountID)"])
            let fresh = try await renew(req)
            do {
                return try await calling(req) { try await body(fresh) }
            } catch GitHubSubmitError.tokenRejected {
                await cache.remove(account: accountID)
                throw GitHubSubmitError.notInstalled
            }
        }
    }

    /// Runs a GitHub call. Any error that is not already a `GitHubSubmitError`
    /// is logged and reported as `githubFailed`, so the student sees one
    /// sentence and no transport detail. Tokens are never logged.
    static func calling<T: Sendable>(
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

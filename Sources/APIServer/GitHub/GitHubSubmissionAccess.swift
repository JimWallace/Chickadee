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
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let secrets = try? GitHubAppSecrets.load(path: req.application.githubAppSecretsFilePath)
        else { throw GitHubSubmitError.unavailable }
        guard let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
        else { throw GitHubSubmitError.notLinked }

        let client = req.application.githubRepoClient
        let token = try await installationToken(
            accountID: link.githubUserID, app: app, secrets: secrets, req: req
        ) { jwt in
            // The installation must be on the linked account itself: a login
            // that has since moved to another GitHub account fails here.
            guard let installation = try await client.findInstallation(jwt, link.githubLogin),
                installation.accountID == link.githubUserID
            else { throw GitHubSubmitError.notInstalled }
            return installation.id
        }
        return GitHubSubmissionAccess(link: link, token: token, client: client)
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
        return try await Self.calling(req) {
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
        let repository = try await Self.calling(req) { try await client.repository(token, id) }
        guard let repository else { throw GitHubSubmitError.repositoryNotFound }
        guard courseRepositoryID != nil || repository.ownerID == githubUserID else {
            throw GitHubSubmitError.notOwner
        }
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

// APIServer/GitHub/GitHubRepoClient.swift
//
// The GitHub calls that submitting a commit makes (docs/github-submissions.md
// slice 3). All of them act as the student's installation of the App, so they
// can read only the repositories the student granted, and only with read
// access.
//
// The calls are closures on the Application, so tests swap in fakes and never
// reach the network (the `GitHubOAuthClient` seam).

import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

/// A student's installation of the App.
struct GitHubInstallation: Sendable, Equatable {
    let id: Int64
    /// The GitHub account the App is installed on.
    let accountID: Int64
}

/// An installation access token and the time it stops working.
struct GitHubInstallationToken: Sendable, Equatable {
    let token: String
    let expiresAt: Date
}

/// A repository, as the submit page needs it.
struct GitHubRepository: Sendable, Equatable {
    let id: Int64
    /// `owner/name`.
    let fullName: String
    let ownerID: Int64
    let defaultBranch: String
    /// Whether only granted people can see the repository. False by default,
    /// so a value nobody read never lets a result reach a public repository.
    var isPrivate = false
}

/// A commit status (slice 6).
struct GitHubCommitStatus: Sendable, Equatable, Content {
    enum State: String, Sendable, Codable {
        case success, failure, error
    }

    let state: State
    let description: String
    let context: String
    let targetURL: String?

    enum CodingKeys: String, CodingKey {
        case state, description, context
        case targetURL = "target_url"
    }
}

/// The head commit of a branch.
struct GitHubCommit: Sendable, Equatable {
    let sha: String
    let message: String
}

struct GitHubRepoClient: Sendable {
    /// The App's installation on the account `login`, or nil when there is none.
    var findInstallation: @Sendable (_ appJWT: String, _ login: String) async throws -> GitHubInstallation?
    /// A new installation access token (valid for one hour).
    var createInstallationToken:
        @Sendable (_ appJWT: String, _ installationID: Int64) async throws -> GitHubInstallationToken
    /// The repositories the installation grants (the first 100).
    var repositories: @Sendable (_ token: String) async throws -> [GitHubRepository]
    /// One repository by its numeric ID, or nil when the installation cannot see it.
    var repository: @Sendable (_ token: String, _ id: Int64) async throws -> GitHubRepository?
    /// The branch names of a repository (the first 100).
    var branches: @Sendable (_ token: String, _ fullName: String) async throws -> [String]
    /// The commit a ref points to, or nil when there is no such ref.
    var commit: @Sendable (_ token: String, _ fullName: String, _ ref: String) async throws -> GitHubCommit?
    /// The gzipped tarball of a commit. Throws `GitHubSubmitError.tooLarge`
    /// when the download is more than `maxBytes`.
    var tarball: @Sendable (_ token: String, _ fullName: String, _ sha: String, _ maxBytes: Int) async throws -> Data

    // MARK: Course repositories (slice 4)
    //
    // Each has a default, so a fake built for slice 3 needs no change. A
    // default refuses rather than succeeds, so a test that forgets one fails.

    /// The template repositories the installation grants (the first 100).
    var templates: @Sendable (_ token: String) async throws -> [GitHubRepository] = { _ in
        throw GitHubSubmitError.unavailable
    }
    /// Makes the private repository `owner/name` from a template.
    var generate:
        @Sendable (_ token: String, _ template: String, _ owner: String, _ name: String) async throws ->
            GitHubRepository = { _, _, _, _ in throw GitHubSubmitError.unavailable }
    /// The current login of the GitHub user with this numeric ID, or nil when
    /// no account has the ID any more. GitHub releases a renamed login for
    /// anyone to take, so a collaborator is invited by the login this returns,
    /// never by a stored one (#1766).
    var userLogin: @Sendable (_ token: String, _ userID: Int64) async throws -> String? = { _, _ in
        throw GitHubSubmitError.unavailable
    }
    /// The App's installation on the account with this numeric ID, with the
    /// account's login now, found by listing the App's installations
    /// (`GET /app/installations`, which the App's JWT may read), or nil. The
    /// fallback when the lookup by the stored login misses, which a renamed
    /// account makes it do (#2206). The default finds none, which is the
    /// answer before this existed.
    var installationByAccountID:
        @Sendable (_ appJWT: String, _ accountID: Int64) async throws -> GitHubUserInstallation? = { _, _ in nil }
    /// Invites `login` to the repository with write access.
    var addCollaborator: @Sendable (_ token: String, _ fullName: String, _ login: String) async throws -> Void =
        { _, _, _ in throw GitHubSubmitError.unavailable }
    /// Whether members may fork the organization's private repositories, or
    /// nil when the installation cannot read the setting.
    var privateForksAllowed: @Sendable (_ token: String, _ organization: String) async throws -> Bool? = { _, _ in
        nil
    }
    /// Archives a repository: it becomes read-only and stays on GitHub.
    var archive: @Sendable (_ token: String, _ fullName: String) async throws -> Void = { _, _ in
        throw GitHubSubmitError.unavailable
    }

    // MARK: Commit statuses (slice 6)

    /// Posts a status on a commit.
    var createStatus:
        @Sendable (_ token: String, _ fullName: String, _ sha: String, _ status: GitHubCommitStatus) async throws ->
            Void = { _, _, _, _ in throw GitHubSubmitError.unavailable }

    // MARK: Granted permissions (#1776)

    /// The permissions and events the App asks for, read with the App JWT.
    var appGrants: @Sendable (_ appJWT: String) async throws -> GitHubAppGrants = { _ in
        throw GitHubSubmitError.unavailable
    }
    /// The permissions and events one installation was granted, read with the
    /// App JWT. Throws `GitHubSubmitError.notInstalled` when the installation
    /// no longer exists.
    var installationGrants: @Sendable (_ appJWT: String, _ installationID: Int64) async throws -> GitHubAppGrants =
        { _, _ in throw GitHubSubmitError.unavailable }
}

extension GitHubRepoClient {
    private struct InstallationBody: Decodable {
        struct Account: Decodable { let id: Int64 }
        let id: Int64
        let account: Account
    }

    private struct TokenBody: Decodable {
        let token: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    private struct RepositoryBody: Decodable {
        struct Owner: Decodable { let id: Int64 }
        let id: Int64
        let fullName: String
        let owner: Owner
        let defaultBranch: String
        let isTemplate: Bool?
        let isPrivate: Bool?

        enum CodingKeys: String, CodingKey {
            case id, owner
            case fullName = "full_name"
            case defaultBranch = "default_branch"
            case isTemplate = "is_template"
            case isPrivate = "private"
        }

        var repository: GitHubRepository {
            GitHubRepository(
                id: id, fullName: fullName, ownerID: owner.id, defaultBranch: defaultBranch,
                isPrivate: isPrivate == true)
        }
    }

    private struct RepositoryList: Decodable {
        let repositories: [RepositoryBody]
    }

    private struct OrganizationBody: Decodable {
        let membersCanForkPrivateRepositories: Bool?

        enum CodingKeys: String, CodingKey {
            case membersCanForkPrivateRepositories = "members_can_fork_private_repositories"
        }
    }

    private struct GenerateBody: Content {
        let owner: String
        let name: String
        let `private`: Bool
    }

    private struct UserBody: Decodable {
        let login: String
    }

    private struct PermissionBody: Content {
        let permission: String
    }

    private struct ArchiveBody: Content {
        let archived: Bool
    }

    /// The part of an App or an installation that says what it may do. Both
    /// fields are absent on an App with no permissions or events.
    private struct GrantsBody: Decodable {
        let permissions: [String: String]?
        let events: [String]?

        var grants: GitHubAppGrants {
            GitHubAppGrants(permissions: permissions ?? [:], events: events ?? [])
        }
    }

    /// GitHub refuses with 403 and no remaining quota, or with 429, when an App
    /// makes repositories too fast.
    static func isRateLimited(_ response: ClientResponse) -> Bool {
        response.status == .tooManyRequests
            || (response.status == .forbidden && response.headers.first(name: "x-ratelimit-remaining") == "0")
    }

    private struct BranchBody: Decodable {
        let name: String
    }

    private struct CommitBody: Decodable {
        struct Details: Decodable { let message: String }
        let sha: String
        let commit: Details
    }

    private static let api = GitHubTransport.api

    /// Escapes one path segment. `/` is escaped too, so a branch name such as
    /// `feature/x` stays one segment.
    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `owner/name` as two escaped path segments.
    static func repoPath(_ fullName: String) -> String {
        fullName.split(separator: "/", omittingEmptySubsequences: false)
            .map { pathSegment(String($0)) }
            .joined(separator: "/")
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The calls every live closure makes, on `GitHubTransport`, which sets
    /// the headers and the timeout and records reachability.
    private struct LiveTransport: Sendable {
        let transport: GitHubTransport

        func get(_ path: String, token: String) async throws -> ClientResponse {
            let response = try await transport.send(
                .GET, api + path, headers: GitHubTransport.apiHeaders(bearer: token))
            return try refusingAStaleToken(response)
        }

        /// A 401 means the token's installation is gone or re-made. The access
        /// layer drops the cached token and resolves once more (#1768).
        func refusingAStaleToken(_ response: ClientResponse) throws -> ClientResponse {
            guard response.status != .unauthorized else { throw GitHubSubmitError.tokenRejected }
            return response
        }

        func send(
            _ method: HTTPMethod, _ path: String, token: String, body: some Content & Sendable
        ) async throws -> ClientResponse {
            let response = try await transport.send(
                method, api + path, headers: GitHubTransport.apiHeaders(bearer: token)
            ) { request in
                try request.content.encode(body, as: .json)
            }
            return try refusingAStaleToken(response)
        }

        func decode<T: Decodable>(_: T.Type, from response: ClientResponse) throws -> T {
            guard response.status == .ok, let body = response.body else { throw GitHubSubmitError.githubFailed }
            return try decoder().decode(T.self, from: Data(buffer: body))
        }
    }

    /// The client that calls api.github.com.
    static func live(app: Application) -> GitHubRepoClient {
        let http = app.http.client.shared
        let github = GitHubTransport(app: app)
        let transport = LiveTransport(transport: github)
        var live = GitHubRepoClient(
            findInstallation: { appJWT, login in
                let response = try await transport.get("/users/\(pathSegment(login))/installation", token: appJWT)
                if response.status == .notFound { return nil }
                let body = try transport.decode(InstallationBody.self, from: response)
                return GitHubInstallation(id: body.id, accountID: body.account.id)
            },
            createInstallationToken: { appJWT, installationID in
                let response = try await github.send(
                    .POST, api + "/app/installations/\(installationID)/access_tokens",
                    headers: GitHubTransport.apiHeaders(bearer: appJWT))
                // The installation ID no longer exists: removed, or re-made
                // under a new ID (#1768).
                if response.status == .notFound { throw GitHubSubmitError.notInstalled }
                guard response.status == .created, let body = response.body else {
                    throw GitHubSubmitError.githubFailed
                }
                let decoded = try decoder().decode(TokenBody.self, from: Data(buffer: body))
                return GitHubInstallationToken(token: decoded.token, expiresAt: decoded.expiresAt)
            },
            repositories: { token in
                let response = try await transport.get("/installation/repositories?per_page=100", token: token)
                return try transport.decode(RepositoryList.self, from: response).repositories.map(\.repository)
            },
            repository: { token, id in
                let response = try await transport.get("/repositories/\(id)", token: token)
                if response.status == .notFound { return nil }
                return try transport.decode(RepositoryBody.self, from: response).repository
            },
            branches: { token, fullName in
                let response = try await transport.get(
                    "/repos/\(repoPath(fullName))/branches?per_page=100", token: token)
                return try transport.decode([BranchBody].self, from: response).map(\.name)
            },
            commit: { token, fullName, ref in
                let response = try await transport.get(
                    "/repos/\(repoPath(fullName))/commits/\(pathSegment(ref))", token: token)
                if response.status == .notFound || response.status == .unprocessableEntity { return nil }
                let body = try transport.decode(CommitBody.self, from: response)
                return GitHubCommit(sha: body.sha, message: body.commit.message)
            },
            tarball: { token, fullName, sha, maxBytes in
                // GitHub answers with a redirect to a short-lived download URL,
                // which the HTTP client follows.
                var request = HTTPClientRequest(url: api + "/repos/\(repoPath(fullName))/tarball/\(pathSegment(sha))")
                request.headers = GitHubTransport.apiHeaders(bearer: token)
                let response = try await app.recordingReachability(.github) {
                    try await http.execute(request, timeout: .seconds(60))
                }
                guard response.status == .ok else { throw GitHubSubmitError.githubFailed }
                do {
                    return Data(buffer: try await response.body.collect(upTo: maxBytes))
                } catch is NIOTooManyBytesError {
                    throw GitHubSubmitError.tooLarge
                }
            })
        addCourseRepositoryCalls(to: &live, transport: transport)
        addGrantCalls(to: &live, transport: transport)
        addInstallationListing(to: &live, transport: transport)
        return live
    }

    /// The #1776 calls, which act as the App rather than as an installation.
    private struct ListedInstallation: Decodable {
        struct Account: Decodable {
            let id: Int64
            let login: String
            let type: String
        }
        let id: Int64
        let account: Account
    }

    /// At most this many pages of 100 are read when an installation is
    /// looked up by account ID.
    static let installationListPages = 20

    private static func addInstallationListing(to live: inout GitHubRepoClient, transport: LiveTransport) {
        live.installationByAccountID = { appJWT, accountID in
            for page in 1...installationListPages {
                let response = try await transport.get("/app/installations?per_page=100&page=\(page)", token: appJWT)
                let listed = try transport.decode([ListedInstallation].self, from: response)
                if let match = listed.first(where: { $0.account.id == accountID }) {
                    return GitHubUserInstallation(
                        installationID: match.id, accountID: match.account.id, accountLogin: match.account.login,
                        accountType: match.account.type)
                }
                if listed.count < 100 { return nil }
            }
            return nil
        }
    }

    private static func addGrantCalls(to live: inout GitHubRepoClient, transport: LiveTransport) {
        live.appGrants = { appJWT in
            let response = try await transport.get("/app", token: appJWT)
            return try transport.decode(GrantsBody.self, from: response).grants
        }
        live.installationGrants = { appJWT, installationID in
            let response = try await transport.get("/app/installations/\(installationID)", token: appJWT)
            if response.status == .notFound { throw GitHubSubmitError.notInstalled }
            return try transport.decode(GrantsBody.self, from: response).grants
        }
    }

    /// The slice-4 calls, apart from `live` so each builder stays readable.
    private static func addCourseRepositoryCalls(to live: inout GitHubRepoClient, transport: LiveTransport) {
        live.templates = { token in
            let response = try await transport.get("/installation/repositories?per_page=100", token: token)
            return try transport.decode(RepositoryList.self, from: response).repositories
                .filter { $0.isTemplate == true }.map(\.repository)
        }
        live.generate = { token, template, owner, name in
            let response = try await transport.send(
                .POST, "/repos/\(repoPath(template))/generate", token: token,
                body: GenerateBody(owner: owner, name: name, private: true))
            if isRateLimited(response) { throw GitHubSubmitError.rateLimited }
            if response.status == .unprocessableEntity { throw GitHubSubmitError.repositoryNameTaken }
            guard response.status == .created, let body = response.body else {
                throw GitHubSubmitError.githubFailed
            }
            return try decoder().decode(RepositoryBody.self, from: Data(buffer: body)).repository
        }
        live.userLogin = { token, userID in
            let response = try await transport.get("/user/\(userID)", token: token)
            if response.status == .notFound { return nil }
            return try transport.decode(UserBody.self, from: response).login
        }
        live.addCollaborator = { token, fullName, login in
            let response = try await transport.send(
                .PUT, "/repos/\(repoPath(fullName))/collaborators/\(pathSegment(login))", token: token,
                body: PermissionBody(permission: "push"))
            if isRateLimited(response) { throw GitHubSubmitError.rateLimited }
            guard response.status == .created || response.status == .noContent else {
                throw GitHubSubmitError.githubFailed
            }
        }
        live.privateForksAllowed = { token, organization in
            let response = try await transport.get("/orgs/\(pathSegment(organization))", token: token)
            guard response.status == .ok else { return nil }
            return try transport.decode(OrganizationBody.self, from: response).membersCanForkPrivateRepositories
        }
        live.createStatus = { token, fullName, sha, status in
            let response = try await transport.send(
                .POST, "/repos/\(repoPath(fullName))/statuses/\(pathSegment(sha))", token: token, body: status)
            guard response.status == .created else { throw GitHubSubmitError.githubFailed }
        }
        live.archive = { token, fullName in
            let response = try await transport.send(
                .PATCH, "/repos/\(repoPath(fullName))", token: token, body: ArchiveBody(archived: true))
            guard response.status == .ok else { throw GitHubSubmitError.githubFailed }
        }
    }
}

private struct GitHubRepoClientKey: StorageKey {
    typealias Value = GitHubRepoClient
}

extension Application {
    /// The live client calls GitHub; tests replace it.
    var githubRepoClient: GitHubRepoClient {
        get { storage[GitHubRepoClientKey.self] ?? .live(app: self) }
        set { storage[GitHubRepoClientKey.self] = newValue }
    }
}

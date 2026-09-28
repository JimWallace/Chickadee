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

        enum CodingKeys: String, CodingKey {
            case id, owner
            case fullName = "full_name"
            case defaultBranch = "default_branch"
        }

        var repository: GitHubRepository {
            GitHubRepository(id: id, fullName: fullName, ownerID: owner.id, defaultBranch: defaultBranch)
        }
    }

    private struct RepositoryList: Decodable {
        let repositories: [RepositoryBody]
    }

    private struct BranchBody: Decodable {
        let name: String
    }

    private struct CommitBody: Decodable {
        struct Details: Decodable { let message: String }
        let sha: String
        let commit: Details
    }

    private static let api = "https://api.github.com"

    private static func headers(token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .accept, value: "application/vnd.github+json")
        headers.replaceOrAdd(name: "X-GitHub-Api-Version", value: "2022-11-28")
        headers.replaceOrAdd(name: .userAgent, value: "Chickadee")
        headers.bearerAuthorization = BearerAuthorization(token: token)
        return headers
    }

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

    /// The client that calls api.github.com.
    static func live(app: Application) -> GitHubRepoClient {
        let client = app.client
        let http = app.http.client.shared
        // Only the transport call is wrapped: a non-2xx answer means GitHub was
        // reached, which the reachability rule must not report as an outage.
        @Sendable func get(_ path: String, token: String) async throws -> ClientResponse {
            try await app.recordingReachability(.github) {
                try await client.get(URI(string: api + path), headers: headers(token: token))
            }
        }
        @Sendable func decode<T: Decodable>(_: T.Type, from response: ClientResponse) throws -> T {
            guard response.status == .ok, let body = response.body else { throw GitHubSubmitError.githubFailed }
            return try decoder().decode(T.self, from: Data(buffer: body))
        }
        return GitHubRepoClient(
            findInstallation: { appJWT, login in
                let response = try await get("/users/\(pathSegment(login))/installation", token: appJWT)
                if response.status == .notFound { return nil }
                let body = try decode(InstallationBody.self, from: response)
                return GitHubInstallation(id: body.id, accountID: body.account.id)
            },
            createInstallationToken: { appJWT, installationID in
                let response = try await app.recordingReachability(.github) {
                    try await client.post(
                        URI(string: api + "/app/installations/\(installationID)/access_tokens"),
                        headers: headers(token: appJWT))
                }
                guard response.status == .created, let body = response.body else {
                    throw GitHubSubmitError.githubFailed
                }
                let decoded = try decoder().decode(TokenBody.self, from: Data(buffer: body))
                return GitHubInstallationToken(token: decoded.token, expiresAt: decoded.expiresAt)
            },
            repositories: { token in
                let response = try await get("/installation/repositories?per_page=100", token: token)
                return try decode(RepositoryList.self, from: response).repositories.map(\.repository)
            },
            repository: { token, id in
                let response = try await get("/repositories/\(id)", token: token)
                if response.status == .notFound { return nil }
                return try decode(RepositoryBody.self, from: response).repository
            },
            branches: { token, fullName in
                let response = try await get("/repos/\(repoPath(fullName))/branches?per_page=100", token: token)
                return try decode([BranchBody].self, from: response).map(\.name)
            },
            commit: { token, fullName, ref in
                let response = try await get("/repos/\(repoPath(fullName))/commits/\(pathSegment(ref))", token: token)
                if response.status == .notFound || response.status == .unprocessableEntity { return nil }
                let body = try decode(CommitBody.self, from: response)
                return GitHubCommit(sha: body.sha, message: body.commit.message)
            },
            tarball: { token, fullName, sha, maxBytes in
                // GitHub answers with a redirect to a short-lived download URL,
                // which the HTTP client follows.
                var request = HTTPClientRequest(url: api + "/repos/\(repoPath(fullName))/tarball/\(pathSegment(sha))")
                request.headers = headers(token: token)
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

// APIServer/GitHub/GitHubOAuthClient.swift
//
// The three GitHub calls that account linking makes (docs/github-submissions.md
// "Linking an account"): exchange the code for a user token, read the user,
// and revoke the token. Chickadee keeps the user's numeric ID and login and
// discards the token, so revoking it right away leaves nothing usable behind.
//
// The calls are closures on the Application, so tests swap in fakes and never
// reach the network (the `GitHubManifestConverter` seam). The live closures go
// through `GitHubTransport`, so each one records GitHub's reachability.

import Foundation
import Vapor

/// The GitHub account a user token belongs to.
struct GitHubUser: Decodable, Sendable, Equatable {
    let id: Int64
    let login: String
}

/// What the code exchange needs.
struct GitHubCodeExchange: Sendable, Equatable {
    let clientID: String
    let clientSecret: String
    let code: String
    let codeVerifier: String
    let redirectURI: String
}

/// An installation of the App that a user can reach (slice 4).
struct GitHubUserInstallation: Sendable, Equatable {
    let installationID: Int64
    let accountID: Int64
    let accountLogin: String
    /// `Organization` or `User`.
    let accountType: String
}

struct GitHubOAuthClient: Sendable {
    /// Exchanges an authorization code for a user access token.
    var exchangeCode: @Sendable (GitHubCodeExchange) async throws -> String
    /// Reads the account a user token belongs to.
    var fetchUser: @Sendable (_ token: String) async throws -> GitHubUser
    /// Revokes a user token. Best effort: a failure is logged, not shown.
    var revokeToken: @Sendable (_ token: String, _ clientID: String, _ clientSecret: String) async throws -> Void
    /// The App's installations that the user can reach (slice 4: binding an
    /// organization to a course).
    var userInstallations: @Sendable (_ token: String) async throws -> [GitHubUserInstallation] = { _ in [] }
    /// The user's role in an organization (`admin` or `member`) while the
    /// membership is active, else nil.
    var organizationRole: @Sendable (_ token: String, _ organization: String) async throws -> String? = { _, _ in
        nil
    }
}

extension GitHubOAuthClient {
    /// Runs `body` with a user token and revokes the token before the outcome
    /// is read, so no path keeps it: a throw from `body` is captured as a
    /// `Result`, the revoke runs, and only then is the result handed back.
    /// Both user-authorization callbacks go through here (#1765): the
    /// account link used to revoke after reading the user, so a failed read
    /// left the token live.
    func withRevokedUserToken<T: Sendable>(
        _ token: String, clientID: String, clientSecret: String, logger: Logger,
        body: (String) async throws -> T
    ) async -> Result<T, any Error> {
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await body(token))
        } catch {
            outcome = .failure(error)
        }
        do {
            try await revokeToken(token, clientID, clientSecret)
        } catch {
            logger.warning("GitHub user token not revoked", metadata: ["error": "\(error)"])
        }
        return outcome
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
        }
    }

    private struct TokenRequest: Content {
        let clientID: String
        let clientSecret: String
        let code: String
        let codeVerifier: String
        let redirectURI: String

        enum CodingKeys: String, CodingKey {
            case code
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case codeVerifier = "code_verifier"
            case redirectURI = "redirect_uri"
        }
    }

    private struct InstallationAccount: Decodable {
        let id: Int64
        let login: String
        let type: String
    }

    private struct InstallationList: Decodable {
        struct Installation: Decodable {
            let id: Int64
            let account: InstallationAccount
        }
        let installations: [Installation]
    }

    private struct Membership: Decodable {
        let state: String
        let role: String
    }

    /// The client that calls github.com and api.github.com, through
    /// `GitHubTransport`.
    static func live(app: Application) -> GitHubOAuthClient {
        let github = GitHubTransport(app: app)
        let api = GitHubTransport.api
        return GitHubOAuthClient(
            exchangeCode: { exchange in
                // The token endpoint is on github.com, not the REST API, and
                // answers JSON only when asked to.
                var headers = HTTPHeaders()
                headers.replaceOrAdd(name: .accept, value: "application/json")
                headers.replaceOrAdd(name: .userAgent, value: GitHubTransport.userAgent)
                let request = TokenRequest(
                    clientID: exchange.clientID, clientSecret: exchange.clientSecret,
                    code: exchange.code, codeVerifier: exchange.codeVerifier,
                    redirectURI: exchange.redirectURI)
                let response = try await github.send(
                    .POST, "https://github.com/login/oauth/access_token", headers: headers
                ) { req in
                    try req.content.encode(request, as: .urlEncodedForm)
                }
                // GitHub answers 200 with an `error` field for a bad code.
                let body = try response.content.decode(TokenResponse.self)
                guard response.status == .ok, body.error == nil, let token = body.accessToken, !token.isEmpty
                else { throw GitHubLinkError.exchangeFailed }
                return token
            },
            fetchUser: { token in
                let response = try await github.send(
                    .GET, api + "/user", headers: GitHubTransport.apiHeaders(bearer: token))
                guard response.status == .ok else { throw GitHubLinkError.exchangeFailed }
                return try response.content.decode(GitHubUser.self)
            },
            revokeToken: { token, clientID, clientSecret in
                var headers = GitHubTransport.apiHeaders()
                headers.basicAuthorization = BasicAuthorization(username: clientID, password: clientSecret)
                let response = try await github.send(
                    .DELETE, api + "/applications/\(GitHubRepoClient.pathSegment(clientID))/token",
                    headers: headers
                ) { req in
                    try req.content.encode(["access_token": token], as: .json)
                }
                guard response.status == .noContent || response.status == .ok else {
                    throw Abort(response.status)
                }
            },
            userInstallations: { token in
                let response = try await github.send(
                    .GET, api + "/user/installations?per_page=100",
                    headers: GitHubTransport.apiHeaders(bearer: token))
                guard response.status == .ok else { throw GitHubLinkError.exchangeFailed }
                return try response.content.decode(InstallationList.self).installations.map {
                    GitHubUserInstallation(
                        installationID: $0.id, accountID: $0.account.id,
                        accountLogin: $0.account.login, accountType: $0.account.type)
                }
            },
            organizationRole: { token, organization in
                let response = try await github.send(
                    .GET, api + "/user/memberships/orgs/\(GitHubRepoClient.pathSegment(organization))",
                    headers: GitHubTransport.apiHeaders(bearer: token))
                if response.status == .notFound || response.status == .forbidden { return nil }
                guard response.status == .ok else { throw GitHubLinkError.exchangeFailed }
                let membership = try response.content.decode(Membership.self)
                return membership.state == "active" ? membership.role : nil
            })
    }
}

private struct GitHubOAuthClientKey: StorageKey {
    typealias Value = GitHubOAuthClient
}

extension Application {
    /// The live client calls GitHub; tests replace it.
    var githubOAuthClient: GitHubOAuthClient {
        get { storage[GitHubOAuthClientKey.self] ?? .live(app: self) }
        set { storage[GitHubOAuthClientKey.self] = newValue }
    }
}

// APIServer/GitHub/GitHubOAuthClient.swift
//
// The three GitHub calls that account linking makes (docs/github-submissions.md
// "Linking an account"): exchange the code for a user token, read the user,
// and revoke the token. Chickadee keeps the user's numeric ID and login and
// discards the token, so revoking it right away leaves nothing usable behind.
//
// The calls are closures on the Application, so tests swap in fakes and never
// reach the network (the `GitHubManifestConverter` seam).

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

struct GitHubOAuthClient: Sendable {
    /// Exchanges an authorization code for a user access token.
    var exchangeCode: @Sendable (GitHubCodeExchange) async throws -> String
    /// Reads the account a user token belongs to.
    var fetchUser: @Sendable (_ token: String) async throws -> GitHubUser
    /// Revokes a user token. Best effort: a failure is logged, not shown.
    var revokeToken: @Sendable (_ token: String, _ clientID: String, _ clientSecret: String) async throws -> Void
}

extension GitHubOAuthClient {
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

    private static func apiHeaders(_ headers: inout HTTPHeaders) {
        headers.replaceOrAdd(name: .accept, value: "application/vnd.github+json")
        headers.replaceOrAdd(name: "X-GitHub-Api-Version", value: "2022-11-28")
        headers.replaceOrAdd(name: .userAgent, value: "Chickadee")
    }

    /// The client that calls github.com and api.github.com.
    static func live(client: any Client) -> GitHubOAuthClient {
        GitHubOAuthClient(
            exchangeCode: { exchange in
                let response = try await client.post(
                    URI(string: "https://github.com/login/oauth/access_token")
                ) { req in
                    req.headers.replaceOrAdd(name: .accept, value: "application/json")
                    req.headers.replaceOrAdd(name: .userAgent, value: "Chickadee")
                    try req.content.encode(
                        TokenRequest(
                            clientID: exchange.clientID, clientSecret: exchange.clientSecret,
                            code: exchange.code, codeVerifier: exchange.codeVerifier,
                            redirectURI: exchange.redirectURI),
                        as: .urlEncodedForm)
                }
                // GitHub answers 200 with an `error` field for a bad code.
                let body = try response.content.decode(TokenResponse.self)
                guard response.status == .ok, body.error == nil, let token = body.accessToken, !token.isEmpty
                else { throw GitHubLinkError.exchangeFailed }
                return token
            },
            fetchUser: { token in
                let response = try await client.get(URI(string: "https://api.github.com/user")) { req in
                    apiHeaders(&req.headers)
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                }
                guard response.status == .ok else { throw GitHubLinkError.exchangeFailed }
                return try response.content.decode(GitHubUser.self)
            },
            revokeToken: { token, clientID, clientSecret in
                let response = try await client.delete(
                    URI(string: "https://api.github.com/applications/\(clientID)/token")
                ) { req in
                    apiHeaders(&req.headers)
                    req.headers.basicAuthorization = BasicAuthorization(
                        username: clientID, password: clientSecret)
                    try req.content.encode(["access_token": token], as: .json)
                }
                guard response.status == .noContent || response.status == .ok else {
                    throw Abort(response.status)
                }
            })
    }
}

private struct GitHubOAuthClientKey: StorageKey {
    typealias Value = GitHubOAuthClient
}

extension Application {
    /// The live client calls GitHub; tests replace it.
    var githubOAuthClient: GitHubOAuthClient {
        get { storage[GitHubOAuthClientKey.self] ?? .live(client: client) }
        set { storage[GitHubOAuthClientKey.self] = newValue }
    }
}

// Route-level enforcement of the operator client allowlist at both
// /oauth/authorize verbs.
//
// The point of the control is that a client the operator has not named cannot
// obtain a consent token OR an authorization code — so these assert the absence
// of the artifact (no MCPConsentRequest row, no code in the redirect), not just
// the status code.

import Core
import Crypto
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct MCPClientAllowlistAuthorizeTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let clientID = "test-agent"
    private let redirectURI = "https://app.example/callback"
    private let codeVerifier = "abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFGH"

    private var codeChallenge: String {
        Self.base64url(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A test app with MCP mounted. `allowlist` seeds the store the way startup
    /// seeds it from `.mcp-client-allowlist`; an empty set is "allow any".
    private func makeApp(allowlist: Set<String>) async throws -> Application {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpClientAllowlistStore = MCPClientAllowlistStore(initialOrigins: allowlist)
        app.mcpClientAllowlistOrigins = allowlist
        return app
    }

    private func seedClient(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: "Test Agent", redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath() -> String {
        var components = URLComponents()
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "content:read content:write"),
            URLQueryItem(name: "state", value: "xyz"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.string ?? "/oauth/authorize"
    }

    private func staffCookie(_ app: Application) async throws -> String {
        let cookie = try await loginUser(
            username: "prof", password: "testpassword", role: "instructor", on: app)
        try await enrollAsTestInstructor(username: "prof", on: app)
        return cookie
    }

    private func getAuthorize(_ app: Application, cookie: String) async throws -> TestingHTTPResponse {
        try await app.asyncSendRequest(
            .GET, authorizePath(),
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) })
    }

    private static func extractRequestToken(_ html: String) throws -> String {
        let marker = "name=\"request_token\" value=\""
        let after = try #require(html.range(of: marker)).upperBound
        let tail = html[after...]
        let end = try #require(tail.firstIndex(of: "\""))
        return String(tail[..<end])
    }

    private func submitConsent(_ app: Application, token: String) async throws -> TestingHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/authorize",
            beforeRequest: { req in
                try req.content.encode(
                    ["request_token": token, "decision": "authorize"], as: .urlEncodedForm)
            })
    }

    // MARK: - GET /oauth/authorize

    @Test func getRefusesAClientOutsideTheAllowlistAndMintsNoConsentToken() async throws {
        // The client's redirect origin (app.example) is not the allowlisted one.
        let app = try await makeApp(allowlist: ["https://claude.ai"])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)

            let res = try await getAuthorize(app, cookie: cookie)
            #expect(res.status == .forbidden)
            // Names the origin that was stopped, so the instructor can tell which
            // tool it was; says nothing about how to get it added. (The JSON
            // error body escapes the slashes, so match on the host + phrasing.)
            #expect(res.body.string.contains("app.example"))
            #expect(res.body.string.contains("not permitted to connect"))

            // The artifact that matters: no consent token was minted, so there is
            // nothing to submit even if the human retries the POST directly.
            let pending = try await MCPConsentRequest.query(on: app.db).count()
            #expect(pending == 0)
        }
    }

    @Test func getRendersConsentForAnAllowlistedClient() async throws {
        let app = try await makeApp(allowlist: ["https://app.example"])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)

            let res = try await getAuthorize(app, cookie: cookie)
            #expect(res.status == .ok)
            #expect(res.body.string.contains("request_token"))
            let pending = try await MCPConsentRequest.query(on: app.db).count()
            #expect(pending == 1)
        }
    }

    @Test func getMatchesTheOriginNotTheFullRedirectURI() async throws {
        // The operator lists an origin; the client's registered callback carries
        // a path. Those must still match.
        let app = try await makeApp(allowlist: ["https://app.example"])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)
            #expect(try await getAuthorize(app, cookie: cookie).status == .ok)
        }
    }

    // MARK: - POST /oauth/authorize

    @Test func postRefusesWhenTheClientWasRemovedAfterTheTokenWasMinted() async throws {
        // The consent token stays submittable for 600s; the allowlist can change
        // inside that window, so the POST re-checks.
        let app = try await makeApp(allowlist: ["https://app.example"])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)

            let html = try await getAuthorize(app, cookie: cookie).body.string
            let token = try Self.extractRequestToken(html)

            // Operator removes the client between render and submit.
            await app.mcpClientAllowlistStore.setOrigins(["https://claude.ai"])

            let res = try await submitConsent(app, token: token)
            #expect(res.status == .forbidden)
            // No authorization code was issued.
            #expect(res.headers.first(name: .location) == nil)
            let codes = try await MCPAuthorizationCode.query(on: app.db).count()
            #expect(codes == 0)
        }
    }

    @Test func postIssuesACodeForAClientStillOnTheAllowlist() async throws {
        let app = try await makeApp(allowlist: ["https://app.example"])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)

            let html = try await getAuthorize(app, cookie: cookie).body.string
            let token = try Self.extractRequestToken(html)

            let res = try await submitConsent(app, token: token)
            #expect(res.status == .seeOther)
            let location = try #require(res.headers.first(name: .location))
            let components = URLComponents(string: location)
            let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
            #expect(code?.isEmpty == false)
        }
    }

    // MARK: - Empty allowlist (no regression)

    @Test func emptyAllowlistLeavesBothVerbsExactlyAsBefore() async throws {
        // The development / existing-test-corpus default: allow any.
        let app = try await makeApp(allowlist: [])
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await staffCookie(app)

            let getRes = try await getAuthorize(app, cookie: cookie)
            #expect(getRes.status == .ok)
            let token = try Self.extractRequestToken(getRes.body.string)

            let postRes = try await submitConsent(app, token: token)
            #expect(postRes.status == .seeOther)
            let location = try #require(postRes.headers.first(name: .location))
            #expect(location.contains("code="))
        }
    }
}

// End-to-end tests for the Phase-2 browser OAuth flow: an instructor consents
// at /oauth/authorize, the client exchanges the PKCE code at /oauth/token for a
// short access token + a rotating refresh token, the access token works against
// /mcp, and the refresh token rotates.  Plus the guard rails: PKCE mismatch,
// deny, and the instructor/admin-only consent gate.

import Crypto
import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPOAuthFlowTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let clientID = "test-agent"
    private let clientName = "Test Agent"
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

    private func makeOAuthApp() async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            enabled: true, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    private func seedClient(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: clientName, redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath(scope: String) -> String {
        var components = URLComponents()
        components.path = "/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: "xyz"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.string ?? "/oauth/authorize"
    }

    /// Runs the consent step and returns the POST response (a 303 to the client).
    private func consent(
        _ app: Application, cookie: String, scope: String, decision: String
    ) async throws -> XCTHTTPResponse {
        let (csrf, bound) = try await csrfFields(for: authorizePath(scope: scope), cookie: cookie, on: app)
        return try await app.asyncSendRequest(
            .POST, "/oauth/authorize",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(
                    [
                        "client_id": clientID, "redirect_uri": redirectURI, "scope": scope,
                        "state": "xyz", "code_challenge": codeChallenge,
                        "code_challenge_method": "S256", "decision": decision, "_csrf": csrf,
                    ], as: .urlEncodedForm)
            })
    }

    private func queryValue(_ name: String, in location: String?) -> String? {
        guard let location, let components = URLComponents(string: location) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func tokenPost(_ app: Application, fields: [String: String]) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/token",
            beforeRequest: { req in try req.content.encode(fields, as: .urlEncodedForm) })
    }

    private func jsonField(_ name: String, in res: XCTHTTPResponse) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
        return object?[name] as? String
    }

    @Test func authorizationCodeThenRefreshFlow() async throws {
        let (app, authority) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)

            // Consent → authorization code.
            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read content:write", decision: "authorize")
            #expect(consentRes.status == .seeOther)
            let location = consentRes.headers.first(name: .location)
            #expect(queryValue("state", in: location) == "xyz")
            let code = try #require(queryValue("code", in: location))

            // Code → access + refresh.
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": codeVerifier,
                ])
            #expect(tokenRes.status == .ok)
            let accessToken = try #require(jsonField("access_token", in: tokenRes))
            let refreshToken = try #require(jsonField("refresh_token", in: tokenRes))

            // Access token represents the human, attributed to the agent.
            let claims = try await authority.verify(accessToken)
            #expect(claims.sub.value == "prof")
            #expect(claims.clientID == clientID)
            #expect(claims.agentName == clientName)
            #expect(claims.scopes.contains("content:write"))

            // The access token actually works against /mcp.
            let mcpRes = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(accessToken)"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(mcpRes.status == .ok)
            #expect(mcpRes.body.string.contains("list_assignments"))

            // Refresh rotates to a fresh pair.
            let refreshRes = try await tokenPost(
                app, fields: ["grant_type": "refresh_token", "refresh_token": refreshToken])
            #expect(refreshRes.status == .ok)
            let rotated = try #require(jsonField("refresh_token", in: refreshRes))
            #expect(rotated != refreshToken)
            let newAccess = try #require(jsonField("access_token", in: refreshRes))
            #expect(try await authority.verify(newAccess).sub.value == "prof")
        }
    }

    @Test func pkceMismatchIsRejected() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let consentRes = try await consent(
                app, cookie: cookie, scope: "content:read", decision: "authorize")
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))

            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID,
                    "code_verifier": "the-wrong-verifier-aaaaaaaaaaaaaaaaaaaaaaaa",
                ])
            #expect(tokenRes.status == .badRequest)
            #expect(tokenRes.body.string.contains("invalid_grant"))
        }
    }

    @Test func denyRedirectsWithAccessDenied() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let res = try await consent(
                app, cookie: cookie, scope: "content:read", decision: "deny")
            #expect(res.status == .seeOther)
            #expect(queryValue("error", in: res.headers.first(name: .location)) == "access_denied")
        }
    }

    @Test func studentCannotAuthorize() async throws {
        let (app, _) = try await makeOAuthApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "student1", password: "testpassword", role: "student", on: app)
            try await app.asyncTest(
                .GET, authorizePath(scope: "content:read"),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("instructors and admins"))
                    #expect(!body.contains("value=\"authorize\""))
                })
        }
    }
}

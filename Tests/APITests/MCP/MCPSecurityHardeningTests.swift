// Security-hardening regression tests for the MCP server, closing gaps found in
// the v0.4.266 audit:
//   • /agents cross-tenant authorization (scoping + IDOR + admin override),
//   • OAuth authorization codes are single-use,
//   • the bearer gate rejects wrong-issuer and bad-signature tokens,
//   • the /mcp Host allowlist rejects a disallowed Host,
//   • Dynamic Client Registration honors the client cap,
//   • NO MCP/OAuth/discovery routes are mounted when MCP is disabled at boot.

import Crypto
import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPSecurityHardeningTests {
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

    // MARK: - App builders

    /// Builds a test app; when `mode` is mounted, mounts the real MCP wiring and
    /// attaches a token authority (issuer/resource matched to the minted tokens).
    private func makeApp(
        mode: MCPMode = .readWrite, allowedHosts: Set<String> = [], maxRegisteredClients: Int = 1000
    ) async throws -> (Application, MCPTokenAuthority?) {
        let mcp = MCPConfig(
            mode: mode, allowedHosts: allowedHosts, allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource,
            maxRegisteredClients: maxRegisteredClients)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        guard mode.isMounted else { return (app, nil) }
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    // MARK: - OAuth flow helpers (mirror MCPOAuthFlowTests)

    private func seedClient(
        _ app: Application, clientID: String, name: String, redirectURI: String
    ) async throws {
        try await MCPOAuthClient(clientID: clientID, name: name, redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath(clientID: String, redirectURI: String, scope: String) -> String {
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

    private func consent(
        _ app: Application, cookie: String, clientID: String, redirectURI: String,
        scope: String, decision: String
    ) async throws -> XCTHTTPResponse {
        // GET the consent screen (authenticated) to mint the single-use token,
        // then submit it. The POST carries no cookie — the token alone guards it.
        var html = ""
        try await app.asyncTest(
            .GET, authorizePath(clientID: clientID, redirectURI: redirectURI, scope: scope),
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in html = res.body.string })
        let marker = "name=\"request_token\" value=\""
        let after = try #require(html.range(of: marker)).upperBound
        let tail = html[after...]
        let end = try #require(tail.firstIndex(of: "\""))
        let token = String(tail[..<end])
        return try await app.asyncSendRequest(
            .POST, "/oauth/authorize",
            beforeRequest: { req in
                try req.content.encode(
                    ["request_token": token, "decision": decision], as: .urlEncodedForm)
            })
    }

    private func tokenPost(_ app: Application, fields: [String: String]) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/token",
            beforeRequest: { req in try req.content.encode(fields, as: .urlEncodedForm) })
    }

    private func queryValue(_ name: String, in location: String?) -> String? {
        guard let location, let components = URLComponents(string: location) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    /// Runs consent → code → token so a persisted `MCPGrant` exists for the
    /// logged-in user behind `cookie`.
    private func createGrant(
        _ app: Application, cookie: String, clientID: String, redirectURI: String, scope: String
    ) async throws {
        let consentRes = try await consent(
            app, cookie: cookie, clientID: clientID, redirectURI: redirectURI,
            scope: scope, decision: "authorize")
        let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
        let tokenRes = try await tokenPost(
            app,
            fields: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": codeVerifier,
            ])
        #expect(tokenRes.status == .ok)
    }

    private func mcpPost(_ app: Application, token: String) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"],
            body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    }

    // MARK: - Routes are not mounted when MCP is disabled at boot

    @Test func disabledMCPMountsNoEndpoints() async throws {
        let (app, _) = try await makeApp(mode: .off)
        try await withApp(app) { app in
            let mcp = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(mcp.status == .notFound)

            // These discovery paths are two-segment, so with the MCP routes
            // unmounted they fall through to the generic web app's vanity route
            // (`/:courseCode/:assignmentSlug`), which 303-redirects an
            // unauthenticated request to /login. The guarantee is that no MCP
            // metadata is served — never a 200 carrying the discovery payload.
            for path in [
                "/.well-known/oauth-protected-resource",
                "/.well-known/oauth-authorization-server",
                "/.well-known/jwks.json",
            ] {
                let res = try await app.asyncSendRequest(.GET, path)
                #expect(
                    res.status == .seeOther || res.status == .notFound,
                    "\(path) must not serve MCP metadata when disabled (got \(res.status))")
            }

            // /oauth/authorize is likewise two-segment → vanity fallthrough, so
            // the consent screen is never rendered.
            let authorize = try await app.asyncSendRequest(.GET, "/oauth/authorize")
            #expect(authorize.status == .seeOther || authorize.status == .notFound)
            let token = try await app.asyncSendRequest(
                .POST, "/oauth/token",
                beforeRequest: { req in
                    try req.content.encode(
                        ["grant_type": "refresh_token", "refresh_token": "x"], as: .urlEncodedForm)
                })
            #expect(token.status == .notFound)
            let register = try await app.asyncSendRequest(
                .POST, "/oauth/register",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(string: #"{"redirect_uris":["https://app.example/cb"]}"#))
            #expect(register.status == .notFound)
        }
    }

    // MARK: - Authorization codes are single-use

    @Test func authorizationCodeCannotBeReplayed() async throws {
        let (app, _) = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app, clientID: clientID, name: clientName, redirectURI: redirectURI)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let consentRes = try await consent(
                app, cookie: cookie, clientID: clientID, redirectURI: redirectURI,
                scope: "content:read", decision: "authorize")
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
            let fields = [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": codeVerifier,
            ]
            let first = try await tokenPost(app, fields: fields)
            #expect(first.status == .ok)
            // Replaying the now-consumed code must fail.
            let replay = try await tokenPost(app, fields: fields)
            #expect(replay.status == .badRequest)
            #expect(replay.body.string.contains("invalid_grant"))
        }
    }

    // MARK: - /agents cross-tenant authorization

    @Test func instructorSeesOnlyOwnConnectedAgents() async throws {
        let (app, _) = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app, clientID: "agent-a", name: "Agent Alpha", redirectURI: redirectURI)
            try await seedClient(app, clientID: "agent-b", name: "Agent Beta", redirectURI: redirectURI)
            let profA = try await loginUser(
                username: "profA", password: "testpassword", role: "instructor", on: app)
            try await createGrant(
                app, cookie: profA, clientID: "agent-a", redirectURI: redirectURI, scope: "content:read")
            let profB = try await loginUser(
                username: "profB", password: "testpassword", role: "instructor", on: app)
            try await createGrant(
                app, cookie: profB, clientID: "agent-b", redirectURI: redirectURI, scope: "content:read")

            try await app.asyncTest(
                .GET, "/agents",
                beforeRequest: { req in req.headers.add(name: .cookie, value: profB) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Agent Beta"))
                    #expect(!res.body.string.contains("Agent Alpha"))
                })
        }
    }

    @Test func instructorCannotRevokeAnotherInstructorsGrant() async throws {
        let (app, _) = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app, clientID: clientID, name: clientName, redirectURI: redirectURI)
            let profA = try await loginUser(
                username: "profA", password: "testpassword", role: "instructor", on: app)
            try await createGrant(
                app, cookie: profA, clientID: clientID, redirectURI: redirectURI, scope: "content:read")
            let grantID = try #require(try await MCPGrant.query(on: app.db).first()).requireID()

            // A second instructor, with a valid CSRF token, attempts the revoke.
            let profB = try await loginUser(
                username: "profB", password: "testpassword", role: "instructor", on: app)
            let (csrf, bound) = try await csrfFields(for: "/agents", cookie: profB, on: app)
            let res = try await app.asyncSendRequest(
                .POST, "/agents/\(grantID.uuidString)/revoke",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: bound)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                })
            #expect(res.status == .forbidden)
            // The grant is untouched (the 403 is authorization, not CSRF).
            let after = try #require(try await MCPGrant.find(grantID, on: app.db))
            #expect(!after.revoked)
        }
    }

    @Test func adminCanRevokeAnyGrant() async throws {
        let (app, _) = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app, clientID: clientID, name: clientName, redirectURI: redirectURI)
            let profA = try await loginUser(
                username: "profA", password: "testpassword", role: "instructor", on: app)
            try await createGrant(
                app, cookie: profA, clientID: clientID, redirectURI: redirectURI, scope: "content:read")
            let grantID = try #require(try await MCPGrant.query(on: app.db).first()).requireID()

            let admin = try await loginUser(
                username: "boss", password: "testpassword", role: "admin", on: app)
            let (csrf, bound) = try await csrfFields(for: "/agents", cookie: admin, on: app)
            let res = try await app.asyncSendRequest(
                .POST, "/agents/\(grantID.uuidString)/revoke",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: bound)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                })
            #expect(res.status == .seeOther)
            let after = try #require(try await MCPGrant.find(grantID, on: app.db))
            #expect(after.revoked)
        }
    }

    // MARK: - Bearer gate rejects bad tokens

    @Test func tokenWithWrongIssuerIsRejected() async throws {
        let (app, maybeAuthority) = try await makeApp()
        let authority = try #require(maybeAuthority)
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: "https://evil.example", audience: resource, ttlSeconds: 3600)
            let res = try await mcpPost(app, token: token)
            #expect(res.status == .unauthorized)
            #expect(res.headers.first(name: .wwwAuthenticate)?.contains("invalid_token") == true)
        }
    }

    @Test func tokenWithBadSignatureIsRejected() async throws {
        let (app, _) = try await makeApp()
        try await withApp(app) { app in
            // A token signed by a DIFFERENT key (same kid) fails signature verify.
            let foreign = try await MCPTokenAuthority.make(
                privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
            let token = try await foreign.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            let res = try await mcpPost(app, token: token)
            #expect(res.status == .unauthorized)
            #expect(res.headers.first(name: .wwwAuthenticate)?.contains("invalid_token") == true)
        }
    }

    // MARK: - /mcp Host allowlist

    @Test func disallowedHostIsRejected() async throws {
        let (app, maybeAuthority) = try await makeApp(allowedHosts: ["allowed.example"])
        let authority = try #require(maybeAuthority)
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            // Valid token (passes the bearer gate) but a Host outside the allowlist.
            let res = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(token)",
                    "Host": "evil.example",
                ],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(res.status == .forbidden)
        }
    }

    // MARK: - Dynamic Client Registration cap

    @Test func registrationStopsAtClientCap() async throws {
        let (app, _) = try await makeApp(maxRegisteredClients: 1)
        try await withApp(app) { app in
            let body = #"{"client_name":"X","redirect_uris":["https://app.example/cb"]}"#
            let first = try await app.asyncSendRequest(
                .POST, "/oauth/register",
                headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body))
            #expect(first.status == .created)
            // The cap (1) is now reached; the next registration is refused.
            let second = try await app.asyncSendRequest(
                .POST, "/oauth/register",
                headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body))
            #expect(second.status == .tooManyRequests)
            #expect(second.body.string.contains("temporarily_unavailable"))
        }
    }
}

// MCP_MODE is the single source of truth for advertised OAuth scopes. These
// tests drive the full custom-connector handshake — DCR → authorize → token →
// initialize → tools/list — through the real `registerMCPRoutes` wiring for
// both read_only and read_write, asserting every spec-facing surface agrees
// with the mode. The regression they guard against: the .well-known docs once
// advertised content:write unconditionally while read_only DCR granted only
// content:read, so Claude asked for a scope the authorize handler refused and
// the browser connect flow died on a claude.ai error page.

import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite struct MCPModeScopeContractTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let redirectURI = "https://app.example/callback"

    /// Builds a test app in `mode` with the real MCP wiring mounted (the same
    /// path the server uses) and a token authority matched to issuer/resource.
    private func makeApp(mode: MCPMode) async throws -> (Application, MCPTokenAuthority) {
        let mcp = MCPConfig(
            mode: mode, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        return (app, authority)
    }

    // MARK: - Request helpers (mirror the real client handshake)

    private func register(_ app: Application) async throws -> TestResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/register",
            headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: #"{"client_name":"Claude","redirect_uris":["\#(redirectURI)"]}"#))
    }

    private func authorizePath(clientID: String, scope: String) -> String {
        mcpAuthorizePath(clientID: clientID, redirectURI: redirectURI, scope: scope)
    }

    /// Renders the consent screen to mint the single-use token, then submits it
    /// (cookie-less, like the cross-site connector POST) and returns the 303.
    private func consent(
        _ app: Application, cookie: String, clientID: String, scope: String
    ) async throws -> TestResponse {
        try await mcpConsent(app, cookie: cookie, authorizePath: authorizePath(clientID: clientID, scope: scope))
    }

    private func scopesSupported(_ res: TestResponse) -> [String]? {
        let object =
            (try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8))) as? [String: Any]
        return object?["scopes_supported"] as? [String]
    }

    // MARK: - Full connect flow, both modes

    /// The end-to-end custom-connector handshake must succeed in both modes, and
    /// every surface must reflect the mode: discovery scopes, DCR grant, the
    /// scope the agent requests, and the tools it can see.
    @Test(arguments: [MCPMode.readOnly, MCPMode.readWrite])
    func connectFlowSucceedsAndScopesMatchMode(_ mode: MCPMode) async throws {
        let expectedScopes = mode.advertisedScopes.map(\.rawValue)
        let (app, _) = try await makeApp(mode: mode)
        try await withApp(app) { app in
            // 1. Discovery: both well-known docs advertise exactly the mode's scopes.
            for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"] {
                try await app.asyncTest(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(scopesSupported(res) == expectedScopes)
                }
            }

            // 2. DCR grants exactly the advertised scopes.
            let regRes = try await register(app)
            #expect(regRes.status == .created)
            let clientID = try #require(jsonField("client_id", in: regRes))
            #expect(jsonField("scope", in: regRes) == expectedScopes.joined(separator: " "))

            // 3. Authorize: the agent requests the granted scope; consent yields a code.
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            // Content consent requires per-course staff now (#417); enrol prof.
            try await enrollAsTestInstructor(username: "prof", on: app)
            let consentRes = try await consent(
                app, cookie: cookie, clientID: clientID, scope: expectedScopes.joined(separator: " "))
            #expect(consentRes.status == .seeOther)
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))

            // 4. Token exchange (authorization_code + PKCE) → access token.
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": mcpTestCodeVerifier,
                ])
            #expect(tokenRes.status == .ok)
            #expect(jsonField("scope", in: tokenRes) == expectedScopes.joined(separator: " "))
            let accessToken = try #require(jsonField("access_token", in: tokenRes))

            // 5. initialize over /mcp with the bearer token succeeds.
            let initRes = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(accessToken)"],
                body: ByteBuffer(
                    string: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(initRes.status == .ok)
            #expect(initRes.body.string.contains("Chickadee MCP"))

            // 6. tools/list reflects the mode: read tools always; write tools only in read_write.
            let listRes = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(accessToken)"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            #expect(listRes.status == .ok)
            let listText = listRes.body.string
            #expect(listText.contains("list_assignments"))
            #expect(listText.contains("update_assignment") == (mode == .readWrite))
            #expect(listText.contains("create_assignment") == (mode == .readWrite))
        }
    }

    // MARK: - Out-of-mode scope is an OAuth error redirect, not a bare 4xx

    /// In read_only, requesting `content:write` at /authorize must redirect to
    /// the client with `error=invalid_scope` (preserving `state`), per OAuth
    /// 2.1 — never a plain HTML/JSON 4xx, which is what left Claude's tab stuck.
    @Test func authorizeRejectsOutOfModeScopeViaErrorRedirect() async throws {
        let (app, _) = try await makeApp(mode: .readOnly)
        try await withApp(app) { app in
            let clientID = try #require(jsonField("client_id", in: try await register(app)))
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await app.asyncTest(
                .GET, authorizePath(clientID: clientID, scope: "content:write"),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers.first(name: .location)
                    #expect(queryValue("error", in: location) == "invalid_scope")
                    #expect(queryValue("state", in: location) == "xyz")
                    // The redirect goes back to the registered client, not an error page.
                    #expect(location?.hasPrefix(redirectURI) == true)
                })
        }
    }

    /// read_only still accepts a `content:read` request (the subset that fits
    /// the mode), proving the rejection above is scope-specific, not blanket.
    @Test func authorizeAcceptsInModeScopeInReadOnly() async throws {
        let (app, _) = try await makeApp(mode: .readOnly)
        try await withApp(app) { app in
            let clientID = try #require(jsonField("client_id", in: try await register(app)))
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            // In-mode consent renders the permitted screen; enrol prof as staff.
            try await enrollAsTestInstructor(username: "prof", on: app)
            try await app.asyncTest(
                .GET, authorizePath(clientID: clientID, scope: "content:read"),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    // Renders the consent screen rather than redirecting with an error.
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Claude"))
                })
        }
    }
}

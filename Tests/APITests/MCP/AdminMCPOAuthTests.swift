// End-to-end tests for the resource-aware OAuth flow against the ADMIN
// diagnostic resource: an admin consents at /oauth/authorize with
// resource=…/admin-mcp + scope=diagnostics:read, exchanges the PKCE code for an
// admin-audience access token, and that token works on /admin-mcp. Plus the
// guard rails: a non-admin instructor cannot authorize the admin resource, and
// the two surfaces' tokens don't cross over.

import Core
import Crypto
import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

// .serialized: each test spins up a full app with two token authorities;
// running them concurrently (on top of the other parallel app-backed suites)
// exhausts the shared connection pool and flakes unrelated suites with
// ConnectionPoolTimeoutError.
@Suite(.serialized) struct AdminMCPOAuthTests {
    private let issuer = "https://chickadee.example"
    private let contentResource = "https://chickadee.example/mcp"
    private let adminResource = "https://chickadee.example/admin-mcp"
    private let clientID = "diag-agent"
    private let clientName = "Diag Agent"
    private let redirectURI = "https://app.example/callback"
    private let codeVerifier = "abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFGH"

    private var codeChallenge: String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
    }

    /// App with BOTH surfaces mounted (content read_write, admin read_only) and
    /// both signing authorities installed, sharing one issuer.
    private func makeApp() async throws -> Application {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: contentResource)
        let admin = AdminMCPConfig(
            mode: .readOnly, allowedHosts: [], allowedOrigins: [],
            signingKeyPath: "unused", issuer: issuer, resource: adminResource)
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp, adminMCP: admin))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.adminMcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "admin-mcp-1")
        return app
    }

    private func seedClient(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: clientName, redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath(scope: String, resource: String?) -> String {
        var components = URLComponents()
        components.path = "/oauth/authorize"
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: "xyz"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        components.queryItems = items
        return components.string ?? "/oauth/authorize"
    }

    private func mintConsentToken(
        _ app: Application, cookie: String, scope: String, resource: String?
    ) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, authorizePath(scope: scope, resource: resource),
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in html = res.body.string })
        let marker = "name=\"request_token\" value=\""
        let after = try #require(html.range(of: marker)).upperBound
        let tail = html[after...]
        let end = try #require(tail.firstIndex(of: "\""))
        return String(tail[..<end])
    }

    private func submitConsent(_ app: Application, token: String) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(
            .POST, "/oauth/authorize",
            beforeRequest: { req in
                try req.content.encode(
                    ["request_token": token, "decision": "authorize"], as: .urlEncodedForm)
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

    private func jsonField(_ name: String, in res: XCTHTTPResponse) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
        return object?[name] as? String
    }

    /// Runs consent → code → token for the admin resource and returns the access token.
    private func adminAccessToken(_ app: Application, cookie: String) async throws -> String {
        let consentToken = try await mintConsentToken(
            app, cookie: cookie, scope: "diagnostics:read", resource: adminResource)
        let consentRes = try await submitConsent(app, token: consentToken)
        let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
        let tokenRes = try await tokenPost(
            app,
            fields: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": codeVerifier,
            ])
        #expect(tokenRes.status == .ok)
        return try #require(jsonField("access_token", in: tokenRes))
    }

    @Test func adminAuthorizesDiagnosticsResourceAndTokenWorks() async throws {
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "the-admin", password: "testpassword", role: "admin", on: app)
            let access = try await adminAccessToken(app, cookie: cookie)

            // Token is minted for the admin audience + diagnostics scope.
            let adminAuthority = try #require(app.adminMcpTokenAuthority)
            let claims = try await adminAuthority.verify(access)
            #expect(claims.aud.value.contains(adminResource))
            #expect(claims.scopes.contains("diagnostics:read"))
            #expect(claims.sub.value == "the-admin")

            // And it actually authenticates against /admin-mcp.
            let res = try await app.asyncSendRequest(
                .POST, "/admin-mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(access)"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(res.status == .ok)
            #expect(res.body.string.contains("get_deployment_info"))
        }
    }

    @Test func instructorCannotAuthorizeAdminResource() async throws {
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            try await app.asyncTest(
                .GET, authorizePath(scope: "diagnostics:read", resource: adminResource),
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    // Admin-resource not-permitted view: "admins" only, no button.
                    #expect(body.contains("only <strong>admins</strong>"))
                    #expect(!body.contains("value=\"authorize\""))
                })
        }
    }

    @Test func adminTokenIsRejectedByContentMcp() async throws {
        // Cross-surface isolation: an admin-audience token must not authenticate
        // against the content /mcp endpoint.
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "the-admin", password: "testpassword", role: "admin", on: app)
            let access = try await adminAccessToken(app, cookie: cookie)
            let res = try await app.asyncSendRequest(
                .POST, "/mcp",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(access)"],
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
            #expect(res.status == .unauthorized)
        }
    }

    @Test func contentFlowStillWorksWhenAdminMounted() async throws {
        // Regression: enabling the admin surface must not disturb the content
        // OAuth path — an instructor still authorizes content scopes normally.
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let consentToken = try await mintConsentToken(
                app, cookie: cookie, scope: "content:read content:write", resource: contentResource)
            let consentRes = try await submitConsent(app, token: consentToken)
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": codeVerifier,
                ])
            let access = try #require(jsonField("access_token", in: tokenRes))
            let contentAuthority = try #require(app.mcpTokenAuthority)
            let claims = try await contentAuthority.verify(access)
            #expect(claims.aud.value.contains(contentResource))
            #expect(claims.scopes.contains("content:write"))
        }
    }
}

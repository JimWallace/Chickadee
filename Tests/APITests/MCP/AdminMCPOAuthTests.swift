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
import VaporTesting

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

    /// App with BOTH surfaces mounted (content read_write, admin read_only) and
    /// both signing authorities installed, sharing one issuer.
    private func makeApp() async throws -> Application {
        let mcp = MCPConfig(
            mode: .readWrite, allowedHosts: [], allowedOrigins: [],
            tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: contentResource)
        // MCP_MODE mounts both the content and the (read-only) admin surface; they
        // share one signing authority, separated only by token audience.
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        app.mcpTokenAuthority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        return app
    }

    private func seedClient(_ app: Application) async throws {
        try await MCPOAuthClient(clientID: clientID, name: clientName, redirectURIs: [redirectURI])
            .save(on: app.db)
    }

    private func authorizePath(scope: String, resource: String?) -> String {
        mcpAuthorizePath(clientID: clientID, redirectURI: redirectURI, scope: scope, resource: resource)
    }

    /// Runs consent → code → token for the admin resource and returns the access token.
    private func adminAccessToken(_ app: Application, cookie: String) async throws -> String {
        let consentToken = try await mintMCPConsentToken(
            app, cookie: cookie, authorizePath: authorizePath(scope: "diagnostics:read", resource: adminResource))
        let consentRes = try await submitMCPConsent(app, token: consentToken)
        let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
        let tokenRes = try await tokenPost(
            app,
            fields: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": mcpTestCodeVerifier,
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

            // Token is minted for the admin audience + diagnostics scope, signed
            // by the shared authority (separation is by audience, not key).
            let adminAuthority = try #require(app.mcpTokenAuthority)
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

    /// POSTs the consent screen's switch-account form in `cookie`'s session.
    private func switchAccount(
        _ app: Application, cookie: String, returnTo: String, csrf: String?
    ) async throws -> TestResponse {
        try await app.asyncSendRequest(
            .POST, MCPOAuthRoutes.switchAccountPath,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                var fields = ["return_to": returnTo]
                if let csrf { fields["_csrf"] = csrf }
                try req.content.encode(fields, as: .urlEncodedForm)
            })
    }

    @Test func instructorSwitchesToAdminAndReturnsToTheSameConsent() async throws {
        // One person, two accounts: the browser is signed in as the instructor,
        // so the admin consent refuses. "Use a different account" signs the
        // browser out and brings the admin back to this same authorize request.
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            _ = try await loginUser(
                username: "the-admin", password: "testpassword", role: "admin", on: app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let path = authorizePath(scope: "diagnostics:read", resource: adminResource)

            var csrf = ""
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let body = res.body.string
                    #expect(body.contains("Signed in as <strong>prof</strong>"))
                    #expect(body.contains("action=\"\(MCPOAuthRoutes.switchAccountPath)\""))
                    csrf = extractCSRFToken(from: body)
                })
            #expect(!csrf.isEmpty)

            let switched = try await switchAccount(app, cookie: cookie, returnTo: path, csrf: csrf)
            #expect(switched.status == .seeOther)
            #expect(switched.headers.first(name: .location) == "/login")
            #expect(switched.headers[.setCookie].contains { $0.hasPrefix("\(reauthMarkerCookieName)=") })

            // The browser is signed out: the consent screen now bounces to /login.
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.headers.first(name: .location) == "/login") })

            // Signing in as the admin in that same browser session returns to
            // the queued authorize request, which now offers Authorize.
            let (loginToken, loginCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            var adminCookie = loginCookie
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: loginCookie)
                    try req.content.encode(
                        ["username": "the-admin", "password": "testpassword", "_csrf": loginToken],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == path)
                    if let c = res.headers.first(name: .setCookie) { adminCookie = c }
                })
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers.add(name: .cookie, value: adminCookie) },
                afterResponse: { res in
                    let body = res.body.string
                    #expect(body.contains("value=\"authorize\""))
                    #expect(body.contains("Signed in as <strong>the-admin</strong>"))
                })
        }
    }

    @Test func switchAccountRefusesAReturnPathOutsideAuthorize() async throws {
        // The form cannot become an open redirect or a sign-out to any page.
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let (csrf, _) = try await csrfFields(
                for: authorizePath(scope: "diagnostics:read", resource: adminResource),
                cookie: cookie, on: app)
            for bad in ["https://evil.example/oauth/authorize?x=1", "//evil.example/", "/admin"] {
                let res = try await switchAccount(app, cookie: cookie, returnTo: bad, csrf: csrf)
                #expect(res.status == .badRequest, "return_to \(bad)")
            }
        }
    }

    @Test func switchAccountRequiresTheCSRFToken() async throws {
        let app = try await makeApp()
        try await withApp(app) { app in
            try await seedClient(app)
            let cookie = try await loginUser(
                username: "prof", password: "testpassword", role: "instructor", on: app)
            let res = try await switchAccount(
                app, cookie: cookie,
                returnTo: authorizePath(scope: "diagnostics:read", resource: adminResource), csrf: nil)
            #expect(res.status == .forbidden)
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
            // Content consent requires per-course staff now (#417); enrol prof.
            try await enrollAsTestInstructor(username: "prof", on: app)
            let consentToken = try await mintMCPConsentToken(
                app, cookie: cookie,
                authorizePath: authorizePath(scope: "content:read content:write", resource: contentResource))
            let consentRes = try await submitMCPConsent(app, token: consentToken)
            let code = try #require(queryValue("code", in: consentRes.headers.first(name: .location)))
            let tokenRes = try await tokenPost(
                app,
                fields: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirectURI, "client_id": clientID, "code_verifier": mcpTestCodeVerifier,
                ])
            let access = try #require(jsonField("access_token", in: tokenRes))
            let contentAuthority = try #require(app.mcpTokenAuthority)
            let claims = try await contentAuthority.verify(access)
            #expect(claims.aud.value.contains(contentResource))
            #expect(claims.scopes.contains("content:write"))
        }
    }
}

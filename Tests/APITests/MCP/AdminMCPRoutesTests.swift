// Tests for the admin "MCP" tab: provisioning non-loginable mcp service
// accounts, minting access tokens (shown once, and only when MCP is active),
// and deletion.  Exercises the CSRF-protected admin POST flow end to end.

import Core
import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AdminMCPRoutesTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    private func makeAdminApp(mcpEnabled: Bool) async throws -> (Application, MCPTokenAuthority?) {
        let mcp: MCPConfig =
            mcpEnabled
            ? MCPConfig(
                enabled: true, allowedHosts: [], allowedOrigins: [],
                tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource)
            : .default
        let app = try await makeTestApp(appConfig: .testDefaults(mcp: mcp))
        var authority: MCPTokenAuthority?
        if mcpEnabled {
            let made = try await MCPTokenAuthority.make(
                privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
            app.mcpTokenAuthority = made
            authority = made
        }
        return (app, authority)
    }

    /// POSTs `fields` to `path` with a freshly-minted CSRF token bound to the
    /// admin session (fetched per call so the test is agnostic to whether the
    /// CSRF middleware treats tokens as single-use).  Threads the session
    /// cookie through in case the GET rotates it.
    private func adminCSRFPost(
        _ app: Application, to path: String, cookie: inout String, fields: [String: String]
    ) async throws -> XCTHTTPResponse {
        let (token, bound) = try await csrfFields(for: "/admin/mcp", cookie: cookie, on: app)
        cookie = bound
        var body = fields
        body["_csrf"] = token
        let boundCookie = cookie
        return try await app.asyncSendRequest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            })
    }

    private func mcpAccount(named username: String, on app: Application) async throws -> APIUser? {
        try await APIUser.query(on: app.db).filter(\.$username == username).first()
    }

    /// Extracts a compact JWT (three base64url segments) from rendered HTML.
    private func extractJWT(from html: String) -> String? {
        let pattern = #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#
        guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
        return String(html[range])
    }

    @Test func createAddsNonLoginableMCPRoleUser() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            let res = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "course-bot"])
            #expect(res.status == .seeOther)
            #expect(res.headers.first(name: .location) == "/admin/mcp")

            let user = try #require(try await mcpAccount(named: "course-bot", on: app))
            #expect(user.role == "mcp")
            #expect(user.isMCPAgent)
            // Non-loginable: the random hash must not match a guessable password.
            #expect(try Bcrypt.verify("course-bot", created: user.passwordHash) == false)
        }
    }

    @Test func createRejectsEmptyUsername() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            let res = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "   "])
            #expect(res.status == .seeOther)
            #expect(res.headers.first(name: .location)?.contains("error=username_required") == true)
            #expect(try await APIUser.query(on: app.db).filter(\.$role == "mcp").count() == 0)
        }
    }

    @Test func mintTokenShowsTokenThatValidates() async throws {
        let (app, authority) = try await makeAdminApp(mcpEnabled: true)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            _ = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "minted-bot"])
            let userID = try #require(try await mcpAccount(named: "minted-bot", on: app)).requireID()

            let res = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts/\(userID.uuidString)/token",
                cookie: &cookie, fields: ["scope": "readwrite"])
            #expect(res.status == .ok)
            let body = res.body.string
            #expect(body.contains("minted-bot"))

            let token = try #require(extractJWT(from: body))
            let unwrappedAuthority = try #require(authority)
            let claims = try await unwrappedAuthority.verify(token)
            #expect(claims.sub.value == "minted-bot")
            #expect(claims.scopes.contains("content:read"))
            #expect(claims.scopes.contains("content:write"))
        }
    }

    @Test func mintTokenWhenDisabledShowsError() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            _ = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "idle-bot"])
            let userID = try #require(try await mcpAccount(named: "idle-bot", on: app)).requireID()

            let res = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts/\(userID.uuidString)/token",
                cookie: &cookie, fields: ["scope": "readwrite"])
            #expect(res.status == .ok)
            #expect(res.body.string.contains("inactive"))
            #expect(extractJWT(from: res.body.string) == nil)
        }
    }

    @Test func deleteRemovesAccount() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            _ = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "gone-bot"])
            let userID = try #require(try await mcpAccount(named: "gone-bot", on: app)).requireID()

            let res = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts/\(userID.uuidString)/delete", cookie: &cookie, fields: [:])
            #expect(res.status == .seeOther)
            #expect(res.headers.first(name: .location) == "/admin/mcp")
            #expect(try await mcpAccount(named: "gone-bot", on: app) == nil)
        }
    }

    @Test func pageListsAccountAndHidesEmptyState() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            var cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            _ = try await adminCSRFPost(
                app, to: "/admin/mcp/accounts", cookie: &cookie, fields: ["username": "shown-bot"])
            let boundCookie = cookie
            try await app.asyncTest(
                .GET, "/admin/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: boundCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("shown-bot"))
                    // Regression: the empty-state must not show once an account exists.
                    #expect(body.contains("No MCP accounts yet.") == false)
                })
        }
    }

    @Test func pageListsConnectedAgentGrants() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: false)
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            let human = try await makeTestUser(on: app, username: "prof-x", role: "instructor")
            try await MCPOAuthClient(
                clientID: "agent-1", name: "Claude Bot", redirectURIs: ["https://x.example/cb"]
            ).save(on: app.db)
            try await MCPGrant(
                userID: human.requireID(), clientID: "agent-1", scope: "content:read content:write",
                refreshTokenHash: "h", expiresAt: Date().addingTimeInterval(86_400)
            ).save(on: app.db)
            try await app.asyncTest(
                .GET, "/admin/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("Connected agents"))
                    #expect(body.contains("Claude Bot"))
                    #expect(body.contains("prof-x"))
                    #expect(body.contains("No connected agents.") == false)
                })
        }
    }

    @Test func pageRendersWithIssuerWhenEnabled() async throws {
        let (app, _) = try await makeAdminApp(mcpEnabled: true)
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "mcp_admin", password: "testpassword", role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/admin/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("MCP service accounts"))
                    #expect(body.contains("chickadee.example"))
                })
        }
    }
}

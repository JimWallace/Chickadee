// Tests/APITests/AdminIntegrationsTests.swift
//
// The admin Integrations pages in the shared row shape: LEARN, MCP, LTI and
// GitHub. The pieces worth pinning are the ones that change what a click does:
// the mint-token scope, the expired pill, the enabled select's value, and the
// edit panel reopening on a validation error.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AdminIntegrationsHelperTests {
    @Test func tokenLifetimesReadInWords() {
        #expect(AdminRoutes.lifetimeText(seconds: 3600) == "1 hour")
        #expect(AdminRoutes.lifetimeText(seconds: 7200) == "2 hours")
        #expect(AdminRoutes.lifetimeText(seconds: 1800) == "30 minutes")
        #expect(AdminRoutes.lifetimeText(seconds: 60) == "1 minute")
        #expect(AdminRoutes.lifetimeText(seconds: 90) == "90 seconds")
    }

    @Test func aGrantIsActiveRevokedOrExpired() {
        func grant(revoked: Bool, expired: Bool) -> AgentGrantRow {
            AgentGrantRow(
                id: "1", agentName: "a", scope: "content:read", owner: "o", createdAt: "x",
                lastUsedAt: nil, expiresAt: "y", revoked: revoked, isExpired: expired)
        }
        #expect(grant(revoked: false, expired: false).statusLabel == "Active")
        #expect(grant(revoked: false, expired: false).canRevoke)
        #expect(grant(revoked: true, expired: false).statusLabel == "Revoked")
        #expect(grant(revoked: false, expired: true).statusLabel == "Expired")
        #expect(!grant(revoked: false, expired: true).canRevoke)
        #expect(!grant(revoked: true, expired: true).canRevoke)
    }
}

@Suite struct AdminMCPPageTests {
    private func makeApp(mode: MCPMode) async throws -> Application {
        let mcp: MCPConfig =
            mode.isMounted
            ? MCPConfig(
                mode: mode, allowedHosts: [], allowedOrigins: [], tokenTTLSeconds: 3600,
                signingKeyPath: "unused", issuer: "https://chickadee.example",
                resource: "https://chickadee.example/mcp")
            : .default
        let app = try await makeTestApp(appConfig: .testDefaults(authMode: .local, mcp: mcp))
        if mode.isMounted {
            app.mcpTokenAuthority = try await MCPTokenAuthority.make(
                privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        }
        return app
    }

    private func page(_ app: Application) async throws -> String {
        let cookie = try await loginUser(
            username: "mcp_page_admin", password: "testpassword", role: "admin", on: app)
        _ = try await makeTestUser(on: app, username: "svc-bot", role: UserRole.mcp.rawValue)
        var html = ""
        try await app.asyncTest(
            .GET, "/admin/mcp",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in html = res.body.string })
        return html
    }

    @Test func readWriteModeOffersTheScopeMenu() async throws {
        let app = try await makeApp(mode: .readWrite)
        try await withApp(app) { app in
            let html = try await page(app)
            #expect(html.contains("tier-open\">Read/write<"))
            #expect(
                html.contains("<button class=\"row-menu-item\" type=\"submit\" role=\"menuitem\">Read + write</button>")
            )
            #expect(html.contains("value=\"readwrite\""))
            #expect(html.contains("value=\"read\""))
        }
    }

    @Test func readOnlyModePostsScopeReadDirectlyAndHasNoScopeMenu() async throws {
        let app = try await makeApp(mode: .readOnly)
        try await withApp(app) { app in
            let html = try await page(app)
            #expect(html.contains("tier-preview\">Read-only<"))
            #expect(html.contains("<strong>Read-only mode.</strong>"))
            #expect(!html.contains("Read + write"))
            #expect(!html.contains("value=\"readwrite\""))
            #expect(html.contains("<input type=\"hidden\" name=\"scope\" value=\"read\">"))
            #expect(html.contains(">Mint token</button>"))
        }
    }

    @Test func anInactiveServerSaysSoAndOffersNoMintButton() async throws {
        let app = try await makeApp(mode: .off)
        try await withApp(app) { app in
            let html = try await page(app)
            #expect(html.contains("tier-danger\">Inactive<"))
            #expect(html.contains("<strong>MCP is inactive.</strong>"))
            #expect(!html.contains("Mint token"))
        }
    }

    @Test func anAccountWithNoCoursesSaysNoAccess() async throws {
        let app = try await makeApp(mode: .readWrite)
        try await withApp(app) { app in
            let html = try await page(app)
            #expect(html.contains("item-details--danger"))
            #expect(html.contains("No course access"))
            #expect(html.contains("Delete account"))
        }
    }

    @Test func agentsShowActiveRevokedAndExpiredWithASpacerWhereThereIsNoMenu() async throws {
        let app = try await makeApp(mode: .readWrite)
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "mcp_grants_admin", password: "testpassword", role: "admin", on: app)
            let owner = try await makeTestUser(on: app, username: "prof-y", role: "user")
            try await MCPOAuthClient(
                clientID: "c1", name: "Bot One", redirectURIs: ["https://x.example/cb"]
            ).save(on: app.db)
            let ownerID = try owner.requireID()
            let live = MCPGrant(
                userID: ownerID, clientID: "c1", scope: "content:read", refreshTokenHash: "h1",
                expiresAt: Date().addingTimeInterval(86_400))
            let old = MCPGrant(
                userID: ownerID, clientID: "c1", scope: "content:read", refreshTokenHash: "h2",
                expiresAt: Date().addingTimeInterval(-86_400))
            let gone = MCPGrant(
                userID: ownerID, clientID: "c1", scope: "content:read", refreshTokenHash: "h3",
                expiresAt: Date().addingTimeInterval(86_400))
            gone.revoked = true
            try await live.save(on: app.db)
            try await old.save(on: app.db)
            try await gone.save(on: app.db)
            var html = ""
            try await app.asyncTest(
                .GET, "/admin/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in html = res.body.string })
            #expect(html.contains("tier-open\">Active<"))
            #expect(html.contains("tier-preview\">Expired<"))
            #expect(html.contains("tier-closed\">Revoked<"))
            // One Revoke menu, for the one grant that still works; the other two rows hold a spacer.
            #expect(html.components(separatedBy: "Revoke agent").count - 1 == 1)
            #expect(html.components(separatedBy: "row-menu-spacer").count - 1 == 2)
            #expect(html.components(separatedBy: "class=\"row-muted\"").count - 1 == 2)
        }
    }
}

@Suite(.serialized) final class AdminLTIPageTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-lti-page")
    }

    private static let form: [String: String] = [
        "displayName": "UW LEARN", "issuer": "https://learn.example.edu", "clientID": "client-1",
        "deploymentIDs": "deployment-1\ndeployment-2",
        "authLoginURL": "https://learn.example.edu/d2l/lti/authenticate",
        "accessTokenURL": "https://auth.example.edu/core/connect/token",
        "jwksURL": "https://learn.example.edu/d2l/.well-known/jwks",
    ]

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "lti_page_admin", password: "testpassword", role: "admin", on: app)
    }

    private func post(_ path: String, _ fields: [String: String], cookie: String) async throws -> String {
        let (token, boundCookie) = try await csrfFields(for: "/admin/lti", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var html = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in html = res.body.string })
        return html
    }

    private func page(cookie: String) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/admin/lti",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in html = res.body.string })
        return html
    }

    @Test func everyToolURLHasACopyButton() async throws {
        try await withApp(app) { _ in
            let html = try await page(cookie: try await loginAsAdmin())
            #expect(html.components(separatedBy: "data-ck-copy=\"").count - 1 == 4)
            #expect(html.contains("+ Register platform"))
            #expect(html.contains("0 platform(s) enabled"))
        }
    }

    @Test func aPlatformRowHasAnEnabledSelectThatSavesOnChangeAndAMutedRowWhenOff() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let platform = try #require(try await APILTIPlatform.query(on: app.db).first())
            var html = try await page(cookie: cookie)
            #expect(html.contains("1 platform(s) enabled"))
            #expect(html.contains("<option value=\"true\" selected>Enabled</option>"))
            #expect(html.contains("data-ck-submit-on-change"))
            #expect(html.contains("action=\"/admin/lti/platforms/\(try platform.requireID())/enabled\""))
            #expect(!html.contains("class=\"row-muted\""))
            _ = try await post(
                "/admin/lti/platforms/\(try platform.requireID())/enabled", ["enabled": "false"],
                cookie: cookie)
            html = try await page(cookie: cookie)
            #expect(html.contains("<option value=\"false\" selected>Disabled</option>"))
            #expect(html.contains("class=\"row-muted\""))
        }
    }

    @Test func aFailedEditReopensItsPanel() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin()
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let id = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()
            var bad = Self.form
            bad["jwksURL"] = "http://learn.example.edu/jwks"
            let html = try await post("/admin/lti/platforms/\(id)", bad, cookie: cookie)
            #expect(html.contains("Key set URL must use https."))
            #expect(html.contains("class=\"add-panel card is-open\" id=\"edit-platform-\(id)\""))
        }
    }

    @Test func deletingKeepsItsConfirmation() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await post("/admin/lti/platforms", Self.form, cookie: cookie)
            let html = try await page(cookie: cookie)
            #expect(html.contains("Delete the platform UW LEARN? Launches from it stop immediately"))
            #expect(html.contains("Delete platform"))
        }
    }
}

@Suite(.serialized) final class AdminIntegrationsPagesTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-integrations")
    }

    private func get(_ path: String) async throws -> String {
        let cookie = try await loginUser(
            username: "integrations_admin", password: "testpassword", role: "admin", on: app)
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    @Test func learnWithoutCredentialsShowsOnlyTheNotice() async throws {
        try await withApp(app) { _ in
            let html = try await get("/admin/brightspace")
            #expect(html.contains("<p class=\"page-crumb\">Integrations</p>"))
            #expect(html.contains("<strong>Not configured.</strong>"))
            #expect(html.contains("BRIGHTSPACE_APP_KEY"))
            #expect(!html.contains("Set the user key"))
            #expect(!html.contains("name=\"userKey\""))
            #expect(html.contains("This page only sets the shared connection.") == false)
        }
    }

    @Test func githubWithoutAnAppShowsTheNotRegisteredPill() async throws {
        try await withApp(app) { _ in
            let html = try await get("/admin/github")
            #expect(html.contains("tier-closed\">Not registered<"))
            #expect(html.contains("No GitHub App registered."))
            #expect(!html.contains("Remove registration"))
        }
    }
}

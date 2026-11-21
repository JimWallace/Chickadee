// Tests/APITests/MCP/AdminMCPPageTests.swift
//
// The admin MCP page in the shared Integrations row shape: the mint-token
// scope per MCP mode, the inactive notice, and the agent grants' active,
// expired and revoked pills.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

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
        let cookie = try await loginAsAdmin("mcp_page_admin", on: app)
        _ = try await makeTestUser(on: app, username: "svc-bot", role: UserRole.mcp.rawValue)
        return try await getHTML("/admin/mcp", cookie: cookie, on: app)
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

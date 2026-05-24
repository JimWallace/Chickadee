// Tests for the MCP OAuth reaper: expired authorization codes and
// revoked/expired grants are deleted, while live records are preserved.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPOAuthReaperTests {
    @Test func reapsExpiredCodesAndDeadGrantsKeepsLiveOnes() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let now = Date()
            // user_id is a FK to users; use a real account for all rows.
            let uid = try await makeTestUser(on: app, username: "reaper-subject").requireID()

            // Authorization codes: one expired, one still live.
            try await MCPAuthorizationCode(
                codeHash: "code-expired", clientID: "c", userID: uid, redirectURI: "r",
                codeChallenge: "x", codeChallengeMethod: "S256", scope: "content:read",
                expiresAt: now.addingTimeInterval(-60)
            ).save(on: app.db)
            try await MCPAuthorizationCode(
                codeHash: "code-live", clientID: "c", userID: uid, redirectURI: "r",
                codeChallenge: "x", codeChallengeMethod: "S256", scope: "content:read",
                expiresAt: now.addingTimeInterval(60)
            ).save(on: app.db)

            // Grants: revoked, expired, and live.
            try await MCPGrant(
                userID: uid, clientID: "c", scope: "content:read",
                refreshTokenHash: "grant-revoked", expiresAt: now.addingTimeInterval(3600),
                revoked: true
            ).save(on: app.db)
            try await MCPGrant(
                userID: uid, clientID: "c", scope: "content:read",
                refreshTokenHash: "grant-expired", expiresAt: now.addingTimeInterval(-3600)
            ).save(on: app.db)
            try await MCPGrant(
                userID: uid, clientID: "c", scope: "content:read",
                refreshTokenHash: "grant-live", expiresAt: now.addingTimeInterval(3600)
            ).save(on: app.db)

            try await reapExpiredMCPOAuthRecords(on: app.db, logger: app.logger, now: now)

            let codeHashes = try await MCPAuthorizationCode.query(on: app.db).all().map(\.codeHash)
            #expect(codeHashes == ["code-live"])
            let grantHashes = try await MCPGrant.query(on: app.db).all().map(\.refreshTokenHash).sorted()
            #expect(grantHashes == ["grant-live"])
        }
    }
}

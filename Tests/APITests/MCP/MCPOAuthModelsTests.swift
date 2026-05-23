// Persistence tests for the Phase-2 OAuth tables (clients, authorization codes,
// grants): confirms the migrations apply and the models round-trip, including
// MCPOAuthClient's newline-delimited redirect-URI accessor.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPOAuthModelsTests {
    @Test func clientPersistsAndParsesRedirectURIs() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let client = MCPOAuthClient(
                clientID: "cid-123", name: "Course Bot",
                redirectURIs: ["https://a.example/cb", "https://b.example/cb"])
            try await client.save(on: app.db)

            let fetched = try #require(
                try await MCPOAuthClient.query(on: app.db).filter(\.$clientID == "cid-123").first())
            #expect(fetched.name == "Course Bot")
            #expect(fetched.redirectURIs == ["https://a.example/cb", "https://b.example/cb"])
            #expect(fetched.isPublic == true)
        }
    }

    @Test func authorizationCodePersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "consenting-human", role: "instructor")
            let userID = try user.requireID()
            let code = MCPAuthorizationCode(
                codeHash: "hash-abc", clientID: "cid-123", userID: userID,
                redirectURI: "https://a.example/cb", codeChallenge: "chal",
                codeChallengeMethod: "S256", scope: "content:read content:write",
                expiresAt: Date().addingTimeInterval(60))
            try await code.save(on: app.db)

            let fetched = try #require(
                try await MCPAuthorizationCode.query(on: app.db).filter(\.$codeHash == "hash-abc").first())
            #expect(fetched.consumed == false)
            #expect(fetched.userID == userID)
            #expect(fetched.scope.contains("content:write"))
        }
    }

    @Test func grantPersists() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "grant-human", role: "instructor")
            let userID = try user.requireID()
            let grant = MCPGrant(
                userID: userID, clientID: "cid-123", scope: "content:read",
                refreshTokenHash: "rt-hash", expiresAt: Date().addingTimeInterval(86_400))
            try await grant.save(on: app.db)

            let fetched = try #require(
                try await MCPGrant.query(on: app.db).filter(\.$refreshTokenHash == "rt-hash").first())
            #expect(fetched.revoked == false)
            #expect(fetched.userID == userID)
        }
    }
}

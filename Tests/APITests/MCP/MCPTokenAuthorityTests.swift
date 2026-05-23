// Tests for MCPTokenAuthority: mint/verify round-trip, key persistence, and
// rejection of expired tokens.

import Foundation
import JWT
import Testing

@testable import APIServer

@Suite struct MCPTokenAuthorityTests {
    @Test func mintAndVerifyRoundTrip() async throws {
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        let token = try await authority.mint(
            subject: "agent-1",
            scopes: [.read, .write],
            issuer: "https://chickadee.example",
            audience: "https://chickadee.example/mcp",
            ttlSeconds: 3600
        )
        let claims = try await authority.verify(token)
        #expect(claims.sub.value == "agent-1")
        #expect(claims.iss.value == "https://chickadee.example")
        #expect(claims.aud.value == ["https://chickadee.example/mcp"])
        #expect(claims.scopes == ["content:read", "content:write"])
    }

    @Test func loadOrGeneratePersistsAndReloadsSameKey() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-key-\(UUID().uuidString).pem").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try await MCPTokenAuthority.loadOrGenerate(path: path, keyID: "k")
        let second = try await MCPTokenAuthority.loadOrGenerate(path: path, keyID: "k")
        let firstPEM = await first.privateKeyPEM
        let secondPEM = await second.privateKeyPEM
        #expect(firstPEM == secondPEM)  // reloaded, not regenerated
    }

    @Test func rejectsExpiredToken() async throws {
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "k")
        let token = try await authority.mint(
            subject: "a", scopes: [.read], issuer: "i", audience: "x", ttlSeconds: -10)
        await #expect(throws: (any Error).self) {
            _ = try await authority.verify(token)
        }
    }
}

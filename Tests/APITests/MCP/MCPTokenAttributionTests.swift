// Verifies the client-attribution claims (client_id / agent_name) survive a
// mint → sign → verify → middleware round-trip and land on the principal, so
// browser-flow tokens can be audited as "human, via agent".  Phase-1 service
// tokens carry no acting client.

import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPTokenAttributionTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let metadataURL = "https://chickadee.example/.well-known/oauth-protected-resource"

    private func makeApp() async throws -> (Application, MCPTokenAuthority) {
        let app = try await Application.make(.testing)
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "k")
        app.mcpTokenAuthority = authority
        let middleware = MCPBearerAuthMiddleware(
            expectedIssuer: issuer, expectedAudience: resource, resourceMetadataURL: metadataURL)
        app.grouped(middleware).get("whoami") { req -> String in
            guard let principal = req.mcpPrincipal else { return "none" }
            return "\(principal.subject)|\(principal.actingClientID ?? "-")|\(principal.actingClientName ?? "-")"
        }
        return (app, authority)
    }

    @Test func clientAttributionRoundTripsToPrincipal() async throws {
        let (app, authority) = try await makeApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "instructor-jane", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600,
                clientID: "agent-xyz", agentName: "Claude Course Bot")
            try await app.testable().test(
                .GET, "/whoami", headers: ["Authorization": "Bearer \(token)"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body) == "instructor-jane|agent-xyz|Claude Course Bot")
            }
        }
    }

    @Test func serviceTokenHasNoActingClient() async throws {
        let (app, authority) = try await makeApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "service-bot", scopes: [.read],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            try await app.testable().test(
                .GET, "/whoami", headers: ["Authorization": "Bearer \(token)"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body) == "service-bot|-|-")
            }
        }
    }
}

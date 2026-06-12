// Tests for MCPBearerAuthMiddleware: missing/invalid token, audience binding,
// insufficient-scope, and the happy path surfacing the principal.

import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPBearerAuthMiddlewareTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"
    private let metadataURL = "https://chickadee.example/.well-known/oauth-protected-resource"

    /// Builds a test app with the authority set and a `/guarded` route behind
    /// the middleware that echoes the principal.
    private func makeGuardedApp() async throws -> (Application, MCPTokenAuthority) {
        let app = try await Application.make(.testing)
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "k")
        app.mcpTokenAuthority = authority
        // The middleware clamps token scopes to the mode's ceiling; mounting it
        // at all implies a mounted, write-capable mode in production.
        app.appConfig = .testDefaults(
            mcp: MCPConfig(
                mode: .readWrite, allowedHosts: [], allowedOrigins: [],
                tokenTTLSeconds: 3600, signingKeyPath: "unused", issuer: issuer, resource: resource))
        let middleware = MCPBearerAuthMiddleware(
            expectedIssuer: issuer, expectedAudience: resource, resourceMetadataURL: metadataURL)
        app.grouped(middleware).get("guarded") { req in
            guard let principal = req.mcpPrincipal else { return "none" }
            let scopes = principal.grantedScopes.map(\.rawValue).sorted().joined(separator: ",")
            return "\(principal.subject):\(scopes)"
        }
        return (app, authority)
    }

    @Test func missingTokenReturns401WithChallenge() async throws {
        let (app, _) = try await makeGuardedApp()
        try await withApp(app) { app in
            try await app.testable().test(.GET, "/guarded") { res async in
                #expect(res.status == .unauthorized)
                #expect(res.headers.first(name: .wwwAuthenticate)?.contains("resource_metadata=") == true)
            }
        }
    }

    @Test func validTokenPassesAndSurfacesPrincipal() async throws {
        let (app, authority) = try await makeGuardedApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "agent", scopes: [.read, .write],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            try await app.testable().test(
                .GET, "/guarded", headers: ["Authorization": "Bearer \(token)"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body) == "agent:content:read,content:write")
            }
        }
    }

    @Test func wrongAudienceReturns401() async throws {
        let (app, authority) = try await makeGuardedApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "a", scopes: [.read],
                issuer: issuer, audience: "https://evil.example/mcp", ttlSeconds: 3600)
            try await app.testable().test(
                .GET, "/guarded", headers: ["Authorization": "Bearer \(token)"]
            ) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func tokenWithoutContentScopeReturns403() async throws {
        let (app, authority) = try await makeGuardedApp()
        try await withApp(app) { app in
            let token = try await authority.mint(
                subject: "a", scopes: [],
                issuer: issuer, audience: resource, ttlSeconds: 3600)
            try await app.testable().test(
                .GET, "/guarded", headers: ["Authorization": "Bearer \(token)"]
            ) { res async in
                #expect(res.status == .forbidden)
                #expect(res.headers.first(name: .wwwAuthenticate)?.contains("insufficient_scope") == true)
            }
        }
    }
}

// Tests for the unauthenticated MCP discovery endpoints: RFC 9728 protected-
// resource metadata and the JWKS export of the ES256 signing key.

import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPMetadataRoutesTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        try app.register(collection: MCPMetadataRoutes(issuer: issuer, resource: resource))
        return app
    }

    @Test func protectedResourceMetadataAdvertisesServerAndScopes() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-protected-resource") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)
                let body = String(buffer: res.body)
                #expect(body.contains("\"resource\""))
                #expect(body.contains("\"authorization_servers\""))
                #expect(body.contains("chickadee.example"))
                #expect(body.contains("content:read"))
                #expect(body.contains("content:write"))
            }
        }
    }

    @Test func jwksExportsTheSigningKey() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/.well-known/jwks.json") { res async in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"kty\":\"EC\""))
                #expect(body.contains("P-256"))
                #expect(body.contains("\"kid\":\"mcp-1\""))
                #expect(body.contains("\"x\""))
                #expect(body.contains("\"y\""))
            }
        }
    }

    @Test func jwksWithoutAuthorityReturnsEmptyKeySet() async throws {
        let app = try await Application.make(.testing)
        try app.register(collection: MCPMetadataRoutes(issuer: issuer, resource: resource))
        try await withApp(app) { app in
            try await app.testable().test(.GET, "/.well-known/jwks.json") { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"keys\":[]"))
            }
        }
    }
}

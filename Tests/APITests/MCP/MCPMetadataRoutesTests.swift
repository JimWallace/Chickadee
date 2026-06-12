// Tests for the unauthenticated MCP discovery endpoints: RFC 9728 protected-
// resource metadata and the JWKS export of the ES256 signing key.

import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct MCPMetadataRoutesTests {
    private let issuer = "https://chickadee.example"
    private let resource = "https://chickadee.example/mcp"

    private func makeApp(
        advertisedScopes: [ContentScope] = MCPMode.readWrite.advertisedScopes
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        let authority = try await MCPTokenAuthority.make(
            privateKeyPEM: ES256PrivateKey().pemRepresentation, keyID: "mcp-1")
        app.mcpTokenAuthority = authority
        try app.register(
            collection: MCPMetadataRoutes(
                endpoints: MCPEndpoints(issuer: issuer, resource: resource, metadataOrigin: issuer),
                advertisedScopes: advertisedScopes))
        return app
    }

    private func scopesSupported(_ res: XCTHTTPResponse) -> [String]? {
        let object =
            (try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8))) as? [String: Any]
        return object?["scopes_supported"] as? [String]
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
                #expect(self.scopesSupported(res) == ["content:read", "content:write"])
            }
        }
    }

    /// In read_only the protected-resource metadata must advertise only
    /// `content:read` — advertising `content:write` here is what made Claude
    /// request a scope the server then refused, breaking the connect flow.
    @Test func protectedResourceMetadataReadOnlyAdvertisesOnlyRead() async throws {
        try await withApp(try await makeApp(advertisedScopes: MCPMode.readOnly.advertisedScopes)) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-protected-resource") { res async in
                #expect(res.status == .ok)
                #expect(self.scopesSupported(res) == ["content:read"])
            }
        }
    }

    @Test func authorizationServerMetadataAdvertisesEndpoints() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-authorization-server") { res async in
                #expect(res.status == .ok)
                // Decode rather than substring-match: Linux's JSONEncoder escapes
                // "/" as "\/", so a raw `contains("/oauth/authorize")` would miss.
                let object =
                    (try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8)))
                    as? [String: Any]
                #expect((object?["authorization_endpoint"] as? String)?.hasSuffix("/oauth/authorize") == true)
                #expect((object?["token_endpoint"] as? String)?.hasSuffix("/oauth/token") == true)
                #expect((object?["registration_endpoint"] as? String)?.hasSuffix("/oauth/register") == true)
                #expect((object?["code_challenge_methods_supported"] as? [String])?.contains("S256") == true)
                #expect((object?["scopes_supported"] as? [String]) == ["content:read", "content:write"])
            }
        }
    }

    /// The authorization-server metadata must mirror the mode too: read_only
    /// advertises only `content:read`.
    @Test func authorizationServerMetadataReadOnlyAdvertisesOnlyRead() async throws {
        try await withApp(try await makeApp(advertisedScopes: MCPMode.readOnly.advertisedScopes)) { app in
            try await app.testable().test(.GET, "/.well-known/oauth-authorization-server") { res async in
                #expect(res.status == .ok)
                #expect(self.scopesSupported(res) == ["content:read"])
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
        try app.register(
            collection: MCPMetadataRoutes(
                endpoints: MCPEndpoints(issuer: issuer, resource: resource, metadataOrigin: issuer),
                advertisedScopes: MCPMode.readWrite.advertisedScopes))
        try await withApp(app) { app in
            try await app.testable().test(.GET, "/.well-known/jwks.json") { res async in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"keys\":[]"))
            }
        }
    }
}

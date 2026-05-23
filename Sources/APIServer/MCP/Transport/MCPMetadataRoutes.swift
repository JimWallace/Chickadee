// APIServer/MCP/Transport/MCPMetadataRoutes.swift
//
// Unauthenticated OAuth discovery endpoints for the MCP resource server:
//   • /.well-known/oauth-protected-resource — RFC 9728 metadata pointing MCP
//     clients at the authorization server and advertising supported scopes.
//   • /.well-known/jwks.json — the ES256 public signing key (RFC 7517) so a
//     client or external verifier can validate access tokens.
// These must stay reachable without a token, so they are mounted outside the
// bearer-gated /mcp group.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Core
import Foundation
import Vapor

struct MCPMetadataRoutes: RouteCollection {
    /// The authorization server identifier advertised to clients (`iss`).
    let issuer: String
    /// The resource identifier this server represents (`aud`, RFC 8707).
    let resource: String

    func boot(routes: RoutesBuilder) throws {
        let wellKnown = routes.grouped(".well-known")
        wellKnown.get("oauth-protected-resource", use: protectedResourceMetadata)
        wellKnown.get("jwks.json", use: jwks)
    }

    /// RFC 9728 protected-resource metadata.
    func protectedResourceMetadata(req: Request) throws -> Response {
        let scopes = ContentScope.allCases.map { JSONValue.string($0.rawValue) }
        let metadata = JSONValue.object([
            "resource": .string(resource),
            "authorization_servers": .array([.string(issuer)]),
            "scopes_supported": .array(scopes),
            "bearer_methods_supported": .array([.string("header")]),
        ])
        return try jsonResponse(metadata)
    }

    /// JWKS export of the active ES256 signing key.  An empty key set is
    /// returned when no authority is configured (the endpoint stays valid JSON).
    func jwks(req: Request) async throws -> Response {
        guard
            let authority = req.application.mcpTokenAuthority,
            let jwk = await authority.publicJWK()
        else {
            return try jsonResponse(.object(["keys": .array([])]))
        }
        let entry = JSONValue.object(jwk.mapValues { JSONValue.string($0) })
        return try jsonResponse(.object(["keys": .array([entry])]))
    }

    private func jsonResponse(_ value: JSONValue) throws -> Response {
        let data = try JSONEncoder().encode(value)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}

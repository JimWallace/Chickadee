// APIServer/MCP/Transport/MCPMetadataRoutes.swift
//
// Unauthenticated OAuth discovery endpoints for the MCP server:
//   • /.well-known/oauth-protected-resource — RFC 9728 metadata pointing MCP
//     clients at the authorization server and advertising supported scopes.
//   • /.well-known/oauth-authorization-server — RFC 8414 metadata advertising
//     the /authorize + /token endpoints, JWKS URI, scopes, grant types, and
//     PKCE methods (so an MCP client can run the browser flow).
//   • /.well-known/jwks.json — the ES256 public signing key (RFC 7517).
// These must stay reachable without a token, so they are mounted outside the
// bearer-gated /mcp group.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Core
import Foundation
import Vapor

struct MCPMetadataRoutes: RouteCollection {
    let endpoints: MCPEndpoints

    func boot(routes: RoutesBuilder) throws {
        let wellKnown = routes.grouped(".well-known")
        wellKnown.get("oauth-protected-resource", use: protectedResourceMetadata)
        wellKnown.get("oauth-authorization-server", use: authorizationServerMetadata)
        wellKnown.get("jwks.json", use: jwks)
    }

    /// RFC 9728 protected-resource metadata.
    func protectedResourceMetadata(req: Request) throws -> Response {
        let scopes = ContentScope.allCases.map { JSONValue.string($0.rawValue) }
        let metadata = JSONValue.object([
            "resource": .string(endpoints.resource),
            "authorization_servers": .array([.string(endpoints.issuer)]),
            "scopes_supported": .array(scopes),
            "bearer_methods_supported": .array([.string("header")]),
        ])
        return try jsonResponse(metadata)
    }

    /// RFC 8414 authorization-server metadata for the browser flow.
    func authorizationServerMetadata(req: Request) throws -> Response {
        let scopes = ContentScope.allCases.map { JSONValue.string($0.rawValue) }
        let metadata = JSONValue.object([
            "issuer": .string(endpoints.issuer),
            "authorization_endpoint": .string(endpoints.authorizationEndpoint),
            "token_endpoint": .string(endpoints.tokenEndpoint),
            "registration_endpoint": .string(endpoints.registrationEndpoint),
            "jwks_uri": .string(endpoints.jwksURL),
            "scopes_supported": .array(scopes),
            "response_types_supported": .array([.string("code")]),
            "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
            "code_challenge_methods_supported": .array([.string("S256")]),
            "token_endpoint_auth_methods_supported": .array([.string("none")]),
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

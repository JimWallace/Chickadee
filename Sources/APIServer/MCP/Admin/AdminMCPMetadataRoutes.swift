// APIServer/MCP/Admin/AdminMCPMetadataRoutes.swift
//
// Unauthenticated RFC 9728 protected-resource discovery for the admin
// diagnostic surface, served at the path-based metadata URL
// `/.well-known/oauth-protected-resource/admin-mcp` (distinct from the content
// surface's root document).  Points MCP clients at the authorization server and
// advertises the admin scope.  Must stay reachable without a token, so it is
// mounted outside the bearer-gated group.

import Core
import Vapor

struct AdminMCPMetadataRoutes: RouteCollection {
    let endpoints: AdminMCPEndpoints
    /// Scopes advertised in the discovery document, derived from ADMIN_MCP_MODE
    /// so the metadata never claims a scope the server won't grant.
    let advertisedScopes: [DiagnosticScope]

    func boot(routes: RoutesBuilder) throws {
        routes.grouped(".well-known", "oauth-protected-resource")
            .get("admin-mcp", use: protectedResourceMetadata)
    }

    func protectedResourceMetadata(req: Request) throws -> Response {
        let scopes = advertisedScopes.map { JSONValue.string($0.rawValue) }
        let metadata = JSONValue.object([
            "resource": .string(endpoints.resource),
            "authorization_servers": .array([.string(endpoints.issuer)]),
            "scopes_supported": .array(scopes),
            "bearer_methods_supported": .array([.string("header")]),
        ])
        let data = try JSONEncoder().encode(metadata)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}

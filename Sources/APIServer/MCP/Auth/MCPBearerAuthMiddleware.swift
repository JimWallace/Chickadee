// APIServer/MCP/Auth/MCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the MCP endpoint.  `MCPBearerVerification`
// validates the token (signature + exp) and enforces issuer and audience;
// this middleware then requires at least one content scope (defence in
// depth, independent of per-tool scopes), clamps it to the server-wide
// ceiling, and surfaces the caller on `request.mcpPrincipal`.  On failure it
// returns 401/403 with a `WWW-Authenticate: Bearer resource_metadata="…"`
// challenge, per the MCP authorization spec.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Vapor

struct MCPBearerAuthMiddleware: AsyncMiddleware {
    let expectedIssuer: String
    let expectedAudience: String
    let resourceMetadataURL: String

    private var verification: MCPBearerVerification {
        MCPBearerVerification(
            expectedIssuer: expectedIssuer,
            expectedAudience: expectedAudience,
            resourceMetadataURL: resourceMetadataURL)
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let claims: MCPAccessTokenClaims
        switch try await verification.verify(request) {
        case .rejected(let response):
            return response
        case .verified(let verified):
            claims = verified
        }

        // Defence in depth: reject tokens carrying no content-authoring scope at
        // all, independent of any per-tool scope check at the dispatcher.
        //
        // The token's scopes are then clamped to the server-wide ceiling for the
        // current MCP_MODE (read_only → {read}).  Applying the ceiling per
        // request — not just at mint time — means a content:write token issued
        // while the server was read_write loses write the instant an operator
        // flips to read_only, with no token revocation.  A token left with no
        // usable scope after clamping is treated as insufficient (the only way
        // that happens today is a write-only token under read_only).
        let ceiling = request.application.appConfig.mcp.mode.scopeCeiling
        let tokenScopes = Set(ContentScope.allCases.filter { claims.scopes.contains($0.rawValue) })
        let granted = tokenScopes.intersection(ceiling)
        guard !granted.isEmpty else {
            return verification.insufficientScope(ceiling.map(\.rawValue))
        }

        request.mcpPrincipal = MCPPrincipal(
            subject: claims.sub.value,
            grantedScopes: granted,
            actingClientID: claims.clientID,
            actingClientName: claims.agentName
        )
        return try await next.respond(to: request)
    }
}

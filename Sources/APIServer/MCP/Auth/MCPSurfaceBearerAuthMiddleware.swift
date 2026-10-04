// APIServer/MCP/Auth/MCPSurfaceBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for an MCP endpoint, shared by the content
// surface (`MCPBearerAuthMiddleware`) and the admin surface
// (`AdminMCPBearerAuthMiddleware`), which used to be two copies that differed
// only in how they grant scopes (#1944). `MCPBearerVerification` validates
// the token (signature + exp) and enforces issuer and audience; this
// middleware then requires at least one of the surface's scopes (defence in
// depth, independent of per-tool scopes), clamps them to the surface's
// ceiling, and surfaces the caller as the request's principal for that
// surface. On failure it returns 401/403 with a
// `WWW-Authenticate: Bearer resource_metadata="…"` challenge, per the MCP
// authorization spec.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Vapor

struct MCPSurfaceBearerAuthMiddleware<Scope>: AsyncMiddleware
where Scope: RawRepresentable & CaseIterable & Hashable & Sendable, Scope.RawValue == String {
    let expectedIssuer: String
    let expectedAudience: String
    let resourceMetadataURL: String
    /// The most a token may grant on this surface for this request.
    let ceiling: @Sendable (Request) -> Set<Scope>

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

        // Defence in depth: reject a token that carries none of this surface's
        // scopes, independent of any per-tool scope check at the dispatcher.
        // The token's scopes are clamped to the ceiling on every request, not
        // only at mint time, and a token left with no usable scope is
        // treated as insufficient.
        let ceiling = ceiling(request)
        let tokenScopes = Set(Scope.allCases.filter { claims.scopes.contains($0.rawValue) })
        let granted = tokenScopes.intersection(ceiling)
        guard !granted.isEmpty else {
            return verification.insufficientScope(ceiling.map(\.rawValue))
        }

        request[mcpPrincipalFor: Scope.self] = MCPSurfacePrincipal(
            subject: claims.sub.value,
            grantedScopes: granted,
            actingClientID: claims.clientID,
            actingClientName: claims.agentName
        )
        return try await next.respond(to: request)
    }
}

/// The content surface's gate. Its ceiling is the server-wide one for the
/// current MCP_MODE (read_only → {read}), so a content:write token issued
/// while the server was read_write loses write the instant an operator flips
/// to read_only, with no token revocation.
typealias MCPBearerAuthMiddleware = MCPSurfaceBearerAuthMiddleware<ContentScope>

extension MCPSurfaceBearerAuthMiddleware where Scope == ContentScope {
    init(expectedIssuer: String, expectedAudience: String, resourceMetadataURL: String) {
        self.init(
            expectedIssuer: expectedIssuer,
            expectedAudience: expectedAudience,
            resourceMetadataURL: resourceMetadataURL,
            ceiling: { $0.application.appConfig.mcp.mode.scopeCeiling })
    }
}

// APIServer/MCP/Admin/AdminMCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the admin diagnostic MCP endpoint.  Parallel
// to `MCPBearerAuthMiddleware`, bound to the admin audience and the
// `DiagnosticScope` vocabulary — so a content token (different audience) can
// never authenticate here, and vice versa.  Token verification and the
// issuer/audience check are `MCPBearerVerification` (the admin surface reuses
// the content signing key; separation is by audience); this middleware
// requires a diagnostic scope and surfaces the caller on
// `request.adminMcpPrincipal`.  The surface is read-only by construction:
// `DiagnosticScope` has no write case, so even under MCP_MODE=read_write only
// `diagnostics:read` is ever granted.

import Vapor

struct AdminMCPBearerAuthMiddleware: AsyncMiddleware {
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

        // The admin surface only honors `diagnostics:read` (there is no write
        // scope), so a token must carry it.  This is independent of MCP_MODE —
        // read_write does not widen the admin surface.
        let granted = Set(DiagnosticScope.allCases.filter { claims.scopes.contains($0.rawValue) })
        guard !granted.isEmpty else {
            return verification.insufficientScope(DiagnosticScope.allCases.map(\.rawValue))
        }

        request.adminMcpPrincipal = AdminMCPPrincipal(
            subject: claims.sub.value,
            grantedScopes: granted,
            actingClientID: claims.clientID,
            actingClientName: claims.agentName
        )
        return try await next.respond(to: request)
    }
}

// APIServer/MCP/Admin/AdminMCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the admin diagnostic MCP endpoint.  Parallel
// to `MCPBearerAuthMiddleware`, bound to the admin audience and the
// `DiagnosticScope` vocabulary — so a content token (different audience) can
// never authenticate here, and vice versa.  Verifies via the shared
// `mcpTokenAuthority` (the admin surface reuses the content signing key;
// separation is by audience), enforces issuer + audience (RFC 8707), requires
// a diagnostic scope, and surfaces the caller on `request.adminMcpPrincipal`.
// The surface is read-only by construction: `DiagnosticScope` has no write case,
// so even under MCP_MODE=read_write only `diagnostics:read` is ever granted.

import Vapor

struct AdminMCPBearerAuthMiddleware: AsyncMiddleware {
    let expectedIssuer: String
    let expectedAudience: String
    let resourceMetadataURL: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let authority = request.application.mcpTokenAuthority else {
            throw Abort(.internalServerError, reason: "MCP token authority is not configured.")
        }
        guard let token = request.headers.bearerAuthorization?.token else {
            return challenge(status: .unauthorized, error: nil, scope: nil)
        }

        let claims: MCPAccessTokenClaims
        do {
            claims = try await authority.verify(token)
        } catch {
            return challenge(status: .unauthorized, error: "invalid_token", scope: nil)
        }

        // RFC 8707: the token must be issued by us and scoped to the ADMIN
        // resource. A content token (audience …/mcp) fails this check.
        guard claims.iss.value == expectedIssuer, claims.aud.value.contains(expectedAudience) else {
            return challenge(status: .unauthorized, error: "invalid_token", scope: nil)
        }

        // The admin surface only honors `diagnostics:read` (there is no write
        // scope), so a token must carry it.  This is independent of MCP_MODE —
        // read_write does not widen the admin surface.
        let granted = Set(DiagnosticScope.allCases.filter { claims.scopes.contains($0.rawValue) })
        guard !granted.isEmpty else {
            return challenge(
                status: .forbidden,
                error: "insufficient_scope",
                scope: DiagnosticScope.allCases.map(\.rawValue).sorted().joined(separator: " ")
            )
        }

        request.adminMcpPrincipal = AdminMCPPrincipal(
            subject: claims.sub.value,
            grantedScopes: granted,
            actingClientID: claims.clientID,
            actingClientName: claims.agentName
        )
        return try await next.respond(to: request)
    }

    private func challenge(status: HTTPResponseStatus, error: String?, scope: String?) -> Response {
        var params = ["Bearer resource_metadata=\"\(resourceMetadataURL)\""]
        if let error { params.append("error=\"\(error)\"") }
        if let scope { params.append("scope=\"\(scope)\"") }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .wwwAuthenticate, value: params.joined(separator: ", "))
        return Response(status: status, headers: headers)
    }
}

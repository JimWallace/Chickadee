// APIServer/MCP/Admin/AdminMCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the admin diagnostic MCP endpoint.  Parallel
// to `MCPBearerAuthMiddleware` but bound to the admin token authority, the admin
// audience, and the `DiagnosticScope` vocabulary — so a content token (different
// audience) can never authenticate here, and vice versa.  Validates signature +
// exp via the admin authority, enforces issuer + audience (RFC 8707), requires
// at least one diagnostic scope after clamping to the ADMIN_MCP_MODE ceiling,
// and surfaces the caller on `request.adminMcpPrincipal`.

import Vapor

struct AdminMCPBearerAuthMiddleware: AsyncMiddleware {
    let expectedIssuer: String
    let expectedAudience: String
    let resourceMetadataURL: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let authority = request.application.adminMcpTokenAuthority else {
            throw Abort(.internalServerError, reason: "Admin MCP token authority is not configured.")
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

        // Clamp the token's scopes to the server-wide ceiling for the current
        // ADMIN_MCP_MODE (read_only → {diagnostics:read}).  A token left with no
        // usable scope after clamping is insufficient.
        let tokenScopes = Set(DiagnosticScope.allCases.filter { claims.scopes.contains($0.rawValue) })
        let granted = tokenScopes.intersection(request.application.appConfig.adminMCP.mode.scopeCeiling)
        guard !granted.isEmpty else {
            return challenge(
                status: .forbidden,
                error: "insufficient_scope",
                scope: request.application.appConfig.adminMCP.mode.scopeCeiling
                    .map(\.rawValue).sorted().joined(separator: " ")
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

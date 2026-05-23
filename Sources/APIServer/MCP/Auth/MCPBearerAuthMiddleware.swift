// APIServer/MCP/Auth/MCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the MCP endpoint.  Validates the token with
// the in-process MCPTokenAuthority (signature + exp), enforces the issuer and
// audience (RFC 8707 — the token must be minted for THIS resource), requires
// at least one content scope (defence in depth, independent of per-tool
// scopes), and surfaces the caller on `request.mcpPrincipal`.  On failure it
// returns 401/403 with a `WWW-Authenticate: Bearer resource_metadata="…"`
// challenge, per the MCP authorization spec.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Vapor

struct MCPBearerAuthMiddleware: AsyncMiddleware {
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

        // RFC 8707: the token must be issued by us and scoped to this resource.
        guard claims.iss.value == expectedIssuer, claims.aud.value.contains(expectedAudience) else {
            return challenge(status: .unauthorized, error: "invalid_token", scope: nil)
        }

        // Defence in depth: reject tokens carrying no content-authoring scope at
        // all, independent of any per-tool scope check at the dispatcher.
        let granted = Set(ContentScope.allCases.filter { claims.scopes.contains($0.rawValue) })
        guard !granted.isEmpty else {
            return challenge(
                status: .forbidden,
                error: "insufficient_scope",
                scope: ContentScope.allCases.map(\.rawValue).joined(separator: " ")
            )
        }

        request.mcpPrincipal = MCPPrincipal(
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

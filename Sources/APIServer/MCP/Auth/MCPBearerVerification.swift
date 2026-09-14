// APIServer/MCP/Auth/MCPBearerVerification.swift
//
// The bearer-token mechanics both MCP endpoints share: reading the
// `Authorization` header, verifying signature + expiry with the in-process
// `MCPTokenAuthority`, enforcing issuer and audience (RFC 8707 — the token
// must be minted for THIS resource), and building the
// `WWW-Authenticate: Bearer resource_metadata="…"` challenge the MCP
// authorization spec prescribes for 401/403.
//
// Each middleware then applies its own scope vocabulary and ceiling
// (`ContentScope` clamped to `MCP_MODE` for `/mcp`, `DiagnosticScope` for
// `/admin-mcp`) — the layer where the two surfaces differ, and the reason the
// audiences differ: a content token can never authenticate on the admin
// resource, and vice versa.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Vapor

struct MCPBearerVerification: Sendable {
    let expectedIssuer: String
    let expectedAudience: String
    let resourceMetadataURL: String

    /// What `verify` decided for one request.
    enum Outcome {
        /// The token is ours, unexpired, and addressed to this resource.
        case verified(MCPAccessTokenClaims)
        /// The 401 to return: no token, an invalid one, or one for another
        /// resource.
        case rejected(Response)
    }

    func verify(_ request: Request) async throws -> Outcome {
        guard let authority = request.application.mcpTokenAuthority else {
            throw Abort(.internalServerError, reason: "MCP token authority is not configured.")
        }
        guard let token = request.headers.bearerAuthorization?.token else {
            return .rejected(challenge(status: .unauthorized, error: nil, scope: nil))
        }

        let claims: MCPAccessTokenClaims
        do {
            claims = try await authority.verify(token)
        } catch {
            return .rejected(challenge(status: .unauthorized, error: "invalid_token", scope: nil))
        }

        // RFC 8707: the token must be issued by us and scoped to this resource.
        guard claims.iss.value == expectedIssuer, claims.aud.value.contains(expectedAudience) else {
            return .rejected(challenge(status: .unauthorized, error: "invalid_token", scope: nil))
        }
        return .verified(claims)
    }

    /// The 403 for a token that carries none of the scopes this resource
    /// honours; `scopes` names what it should have carried.
    func insufficientScope(_ scopes: [String]) -> Response {
        challenge(
            status: .forbidden,
            error: "insufficient_scope",
            scope: scopes.sorted().joined(separator: " "))
    }

    func challenge(status: HTTPResponseStatus, error: String?, scope: String?) -> Response {
        var params = ["Bearer resource_metadata=\"\(resourceMetadataURL)\""]
        if let error { params.append("error=\"\(error)\"") }
        if let scope { params.append("scope=\"\(scope)\"") }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .wwwAuthenticate, value: params.joined(separator: ", "))
        return Response(status: status, headers: headers)
    }
}

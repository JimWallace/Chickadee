// APIServer/MCP/Auth/MCPAccessTokenClaims.swift
//
// Claims carried by an MCP access token.  JWTKit verifies the signature and we
// verify `exp` here; `iss` / `aud` / scopes are checked by the bearer
// middleware (matching the project's OIDCIDTokenClaims pattern, where iss/aud
// are validated manually after decode).

import JWT

struct MCPAccessTokenClaims: JWTPayload, Sendable {
    var sub: SubjectClaim
    var iss: IssuerClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var iat: IssuedAtClaim?
    /// Space-delimited OAuth scopes (RFC 6749 §3.3), e.g. "content:read content:write".
    var scope: String?
    /// The OAuth client (agent) the token was issued through, when minted via
    /// the browser flow.  Nil for Phase-1 admin-minted service tokens, where the
    /// subject itself is the agent.  Carried for audit attribution, not authz.
    var clientID: String?
    /// Human-readable name of that client, for audit/logging.
    var agentName: String?

    private enum CodingKeys: String, CodingKey {
        case sub, iss, aud, exp, iat, scope
        case clientID = "client_id"
        case agentName = "agent_name"
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    /// The token's scopes, parsed from the space-delimited `scope` claim.
    var scopes: Set<String> {
        Set((scope ?? "").split(separator: " ").map(String.init))
    }
}

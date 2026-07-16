// APIServer/MCP/OAuth/MCPOAuthRoutes.swift
//
// The Phase-2 browser OAuth 2.1 flow (Chickadee as its own authorization
// server):
//
//   GET  /oauth/authorize  — validate the client/redirect/PKCE, require a
//                            logged-in instructor/admin, render the consent
//                            screen.  Unauthenticated users are bounced through
//                            /login (returnTo stashed in the session).
//   POST /oauth/authorize  — record consent, mint a single-use PKCE code, and
//                            redirect back to the client with code + state.
//   POST /oauth/token      — exchange the code (+ PKCE verifier) for a short
//                            access token + a long rotating refresh token, or
//                            rotate a refresh token for a fresh pair.
//
// The access token's subject is the human; the agent (OAuth client) rides along
// in the client_id/agent_name claims for audit attribution.  Codes and refresh
// tokens are stored only as SHA-256 hashes.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
//
// This file owns the collection struct itself plus the helpers shared by every
// grant path.  The handlers live in sibling extension files, split along the
// original MARK seams (#1122, following the v0.4.37 large-source splits):
//
//   MCPOAuthRoutes+Authorize.swift    — GET/POST /oauth/authorize (consent)
//   MCPOAuthRoutes+Token.swift        — POST /oauth/token (+ atomic burn/rotate)
//   MCPOAuthRoutes+Registration.swift — POST /oauth/register, /oauth/revoke
//   MCPOAuthSurface.swift             — content vs admin surface resolution
//   MCPOAuthWireTypes.swift           — wire DTOs
//
// Route registration stays in MCPServerRegistration.registerMCPOAuthRoutes.

import Foundation

struct MCPOAuthRoutes: Sendable {
    let endpoints: MCPEndpoints
    let accessTokenTTLSeconds: Int
    let grantTTLDays: Int
    /// Cap on total dynamically-registered clients (anti-flooding backstop).
    var maxRegisteredClients: Int = 1000
    /// Cap on `redirect_uris` accepted in one registration.
    var maxRedirectURIsPerClient: Int = 5

    /// Session key holding the authorize URL a user was bounced to /login from;
    /// honored by `postLoginRedirect`.
    static let returnToSessionKey = "mcpOAuthReturnTo"

    /// Shared by the authorize, token, and registration extensions (consent
    /// tokens, codes, refresh tokens, client IDs).
    static func randomToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncodedString()
    }
}

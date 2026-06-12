// APIServer/MCP/Auth/MCPPrincipal.swift
//
// The authenticated caller behind an MCP request, set by the bearer middleware
// and read by the route when it builds the ToolContext (subject + scopes).

import Vapor

struct MCPPrincipal: Sendable {
    let subject: String
    let grantedScopes: Set<ContentScope>
    /// The OAuth client (agent) the request was authorized through, when the
    /// token carries one (browser flow).  Nil for Phase-1 service tokens.
    let actingClientID: String?
    /// Human-readable name of that client, for audit attribution.
    let actingClientName: String?

    init(
        subject: String,
        grantedScopes: Set<ContentScope>,
        actingClientID: String? = nil,
        actingClientName: String? = nil
    ) {
        self.subject = subject
        self.grantedScopes = grantedScopes
        self.actingClientID = actingClientID
        self.actingClientName = actingClientName
    }
}

private struct MCPPrincipalKey: StorageKey {
    typealias Value = MCPPrincipal
}

extension Request {
    /// The MCP principal established by `MCPBearerAuthMiddleware` once a bearer
    /// token has passed validation.  Nil on unauthenticated requests.
    var mcpPrincipal: MCPPrincipal? {
        get { storage[MCPPrincipalKey.self] }
        set { storage[MCPPrincipalKey.self] = newValue }
    }
}

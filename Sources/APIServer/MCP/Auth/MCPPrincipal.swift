// APIServer/MCP/Auth/MCPPrincipal.swift
//
// The authenticated caller behind an MCP request, set by the bearer middleware
// and read by the route when it builds the ToolContext (subject + scopes).

import Vapor

struct MCPPrincipal: Sendable {
    let subject: String
    let grantedScopes: Set<ContentScope>
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

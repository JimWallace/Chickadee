// APIServer/MCP/Auth/MCPSurfacePrincipal.swift
//
// The authenticated caller behind an MCP request, set by a bearer middleware
// and read by the route when it builds the tool context (subject + scopes).
// One generic type serves both surfaces: the content surface's `MCPPrincipal`
// and the admin surface's `AdminMCPPrincipal` differed only in their scope
// type (#1944).

import Vapor

/// The authenticated caller on one MCP surface. `Scope` is that surface's
/// scope type.
struct MCPSurfacePrincipal<Scope: Hashable & Sendable>: Sendable {
    let subject: String
    let grantedScopes: Set<Scope>
    /// The OAuth client (agent) the request was authorized through, when the
    /// token carries one (browser flow). Nil for directly-minted tokens.
    let actingClientID: String?
    /// Human-readable name of that client, for audit attribution.
    let actingClientName: String?

    init(
        subject: String,
        grantedScopes: Set<Scope>,
        actingClientID: String? = nil,
        actingClientName: String? = nil
    ) {
        self.subject = subject
        self.grantedScopes = grantedScopes
        self.actingClientID = actingClientID
        self.actingClientName = actingClientName
    }
}

/// The content-surface caller.
typealias MCPPrincipal = MCPSurfacePrincipal<ContentScope>

/// One storage slot per surface: the scope type tells them apart.
private struct MCPSurfacePrincipalKey<Scope: Hashable & Sendable>: StorageKey {
    typealias Value = MCPSurfacePrincipal<Scope>
}

extension Request {
    /// The MCP principal established by `MCPBearerAuthMiddleware` once a bearer
    /// token has passed validation. Nil on unauthenticated requests.
    var mcpPrincipal: MCPPrincipal? {
        get { storage[MCPSurfacePrincipalKey<ContentScope>.self] }
        set { storage[MCPSurfacePrincipalKey<ContentScope>.self] = newValue }
    }

    /// The admin MCP principal established by `AdminMCPBearerAuthMiddleware`
    /// once a bearer token has passed validation. Nil on unauthenticated
    /// requests.
    var adminMcpPrincipal: AdminMCPPrincipal? {
        get { storage[MCPSurfacePrincipalKey<DiagnosticScope>.self] }
        set { storage[MCPSurfacePrincipalKey<DiagnosticScope>.self] = newValue }
    }
}

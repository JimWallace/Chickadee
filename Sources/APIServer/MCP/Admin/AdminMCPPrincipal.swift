// APIServer/MCP/Admin/AdminMCPPrincipal.swift
//
// The authenticated caller behind an admin diagnostic MCP request, set by
// `AdminMCPBearerAuthMiddleware` and read by `AdminMCPRoutes` when it builds the
// `AdminToolContext`.  Parallel to `MCPPrincipal` but over `DiagnosticScope`.
// Also home to the admin token authority's Application storage — a separate
// authority instance (and signing key) from the content surface's, so rotating
// the admin key revokes admin tokens without touching content grants.

import Vapor

struct AdminMCPPrincipal: Sendable {
    let subject: String
    let grantedScopes: Set<DiagnosticScope>
    /// The OAuth client (agent) the request was authorized through (browser
    /// flow); nil for directly-minted tokens.  Carried for audit attribution.
    let actingClientID: String?
    let actingClientName: String?

    init(
        subject: String,
        grantedScopes: Set<DiagnosticScope>,
        actingClientID: String? = nil,
        actingClientName: String? = nil
    ) {
        self.subject = subject
        self.grantedScopes = grantedScopes
        self.actingClientID = actingClientID
        self.actingClientName = actingClientName
    }
}

private struct AdminMCPPrincipalKey: StorageKey {
    typealias Value = AdminMCPPrincipal
}

extension Request {
    /// The admin MCP principal established by `AdminMCPBearerAuthMiddleware` once
    /// a bearer token has passed validation.  Nil on unauthenticated requests.
    var adminMcpPrincipal: AdminMCPPrincipal? {
        get { storage[AdminMCPPrincipalKey.self] }
        set { storage[AdminMCPPrincipalKey.self] = newValue }
    }
}

private struct AdminMCPTokenAuthorityKey: StorageKey {
    typealias Value = MCPTokenAuthority
}

extension Application {
    /// The admin MCP token authority, loaded at startup when
    /// `appConfig.adminMCP.mode` is mounted.  Separate from `mcpTokenAuthority`
    /// (the content surface) — its own ES256 signing key.
    var adminMcpTokenAuthority: MCPTokenAuthority? {
        get { storage[AdminMCPTokenAuthorityKey.self] }
        set { storage[AdminMCPTokenAuthorityKey.self] = newValue }
    }
}

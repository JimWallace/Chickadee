// APIServer/MCP/Admin/AdminMCPPrincipal.swift
//
// The authenticated caller behind an admin diagnostic MCP request, set by
// `AdminMCPBearerAuthMiddleware` and read by `AdminMCPRoutes` when it builds the
// `AdminToolContext`.  Parallel to `MCPPrincipal` but over `DiagnosticScope`.
// The admin surface shares the content surface's signing key/authority
// (`Application.mcpTokenAuthority`); separation comes from the distinct token
// audience (…/admin-mcp), not a separate key.

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

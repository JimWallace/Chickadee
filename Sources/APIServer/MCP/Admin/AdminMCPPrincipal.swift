// APIServer/MCP/Admin/AdminMCPPrincipal.swift
//
// The authenticated caller behind an admin diagnostic MCP request, set by
// `AdminMCPBearerAuthMiddleware` and read by `AdminMCPRoutes` when it builds the
// `AdminToolContext`. The type is `MCPSurfacePrincipal` over `DiagnosticScope`;
// `Request.adminMcpPrincipal` sits beside the content accessor in
// `MCPSurfacePrincipal.swift`. The admin surface shares the content surface's
// signing key/authority (`Application.mcpTokenAuthority`); separation comes from
// the distinct token audience (…/admin-mcp), not a separate key.

/// The admin-surface caller.
typealias AdminMCPPrincipal = MCPSurfacePrincipal<DiagnosticScope>

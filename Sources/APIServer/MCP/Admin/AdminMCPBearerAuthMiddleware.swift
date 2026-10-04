// APIServer/MCP/Admin/AdminMCPBearerAuthMiddleware.swift
//
// OAuth 2.1 bearer-token gate for the admin diagnostic MCP endpoint: the
// shared `MCPSurfaceBearerAuthMiddleware`, bound to the admin audience and the
// `DiagnosticScope` vocabulary, so a content token (different audience) can
// never authenticate here, and vice versa. The admin surface reuses the
// content signing key; separation is by audience. The surface is read-only by
// construction: `DiagnosticScope` has no write case, so even under
// MCP_MODE=read_write only `diagnostics:read` is ever granted.

import Vapor

/// The admin surface's gate.
typealias AdminMCPBearerAuthMiddleware = MCPSurfaceBearerAuthMiddleware<DiagnosticScope>

extension MCPSurfaceBearerAuthMiddleware where Scope == DiagnosticScope {
    /// The ceiling is every diagnostic scope, independent of MCP_MODE:
    /// read_write does not widen the admin surface.
    init(expectedIssuer: String, expectedAudience: String, resourceMetadataURL: String) {
        self.init(
            expectedIssuer: expectedIssuer,
            expectedAudience: expectedAudience,
            resourceMetadataURL: resourceMetadataURL,
            ceiling: { _ in Set(DiagnosticScope.allCases) })
    }
}

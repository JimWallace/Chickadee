// APIServer/MCP/Admin/AdminMCPServerRegistration.swift
//
// Wires the admin diagnostic MCP surface into the live application.  It is tied
// to the content surface's `MCP_MODE` — all-or-nothing: when MCP is mounted
// (read_only OR read_write) the read-only /admin-mcp transport + its
// protected-resource discovery mount too; when MCP is off, neither does.  There
// are no ADMIN_MCP_* settings: issuer/guards/key are the content surface's, and
// the admin resource is derived as `<origin>/admin-mcp`.  Even under
// MCP_MODE=read_write the admin surface stays read-only — it only ever advertises
// and honors `diagnostics:read`.

import Core
import Vapor

/// The fixed scope the admin diagnostic surface advertises and honors whenever
/// it is mounted — always read-only, regardless of MCP_MODE.
let adminMCPAdvertisedScopes: [DiagnosticScope] = [.read]

/// Resolved OAuth identifiers + endpoint URLs for the admin MCP surface, derived
/// from the content surface's resolved endpoints (shared issuer + origin).
struct AdminMCPEndpoints {
    let issuer: String
    let resource: String
    let metadataOrigin: String

    /// RFC 9728 path-based metadata URL for the admin resource — distinct from
    /// the content surface's root `…/.well-known/oauth-protected-resource`.
    var resourceMetadataURL: String {
        metadataOrigin + "/.well-known/oauth-protected-resource/admin-mcp"
    }

    /// Derives the admin endpoints from the content `MCPConfig`: same issuer and
    /// origin, with the resource at `<origin>/admin-mcp`.  Returns nil when the
    /// content endpoints can't be resolved (no issuer/PUBLIC_BASE_URL).
    static func resolve(
        mcp: MCPConfig, security: AppSecurityConfiguration
    ) -> AdminMCPEndpoints? {
        guard let content = MCPEndpoints.resolve(mcp: mcp, security: security) else { return nil }
        return AdminMCPEndpoints(
            issuer: content.issuer,
            resource: content.metadataOrigin + "/admin-mcp",
            metadataOrigin: content.metadataOrigin)
    }
}

/// Registers the admin MCP endpoint + discovery metadata when MCP is mounted; a
/// no-op otherwise.  Called from `routes(_:)`.
func registerAdminMCPRoutes(_ app: Application) throws {
    let mcp = app.appConfig.mcp
    guard mcp.mode.isMounted else { return }
    guard let endpoints = AdminMCPEndpoints.resolve(mcp: mcp, security: app.appConfig.security) else {
        app.logger.warning(
            "MCP_MODE=\(mcp.mode.rawValue) but no issuer/resource could be resolved; /admin-mcp not mounted."
        )
        return
    }

    // Reuse the content surface's production DNS-rebinding fail-safe + guards.
    if let refusal = mcpTransportGuardRefusal(
        environment: app.environment,
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins,
        allowOpenGuards: mcp.allowOpenTransportGuards)
    {
        app.logger.error("admin-mcp: \(refusal)")
        return
    }
    if let warning = mcpAllowlistWarning(
        environment: app.environment,
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins)
    {
        app.logger.warning("admin-mcp: \(warning)")
    }

    let dispatcher = AdminMCPDispatcher(
        serverInfo: MCPServerInfo(
            name: "Chickadee Admin MCP", version: ChickadeeVersion.current,
            title: "Chickadee Admin Diagnostics"),
        tools: AdminMCPToolCatalog.live
    )
    let routeConfiguration = MCPRoutes.Configuration(
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins,
        resourceMetadataURL: endpoints.resourceMetadataURL
    )
    let bearer = AdminMCPBearerAuthMiddleware(
        expectedIssuer: endpoints.issuer,
        expectedAudience: endpoints.resource,
        resourceMetadataURL: endpoints.resourceMetadataURL
    )

    try app.grouped(bearer).register(
        collection: AdminMCPRoutes(dispatcher: dispatcher, configuration: routeConfiguration))
    try app.register(
        collection: AdminMCPMetadataRoutes(
            endpoints: endpoints, advertisedScopes: adminMCPAdvertisedScopes))

    app.logger.info(
        "Admin MCP endpoint mounted at /admin-mcp (read-only) — issuer=\(endpoints.issuer), resource=\(endpoints.resource)"
    )
}

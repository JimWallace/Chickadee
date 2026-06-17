// APIServer/MCP/Admin/AdminMCPServerRegistration.swift
//
// Wires the admin diagnostic MCP surface into the live application when
// `appConfig.adminMCP.mode` is mounted (read_only).  Mounts the bearer-gated
// /admin-mcp transport and the unauthenticated protected-resource discovery
// document.  Parallel to `registerMCPRoutes` (the content surface); reuses its
// production DNS-rebinding fail-safe helpers.  Issuer/resource resolve from
// AdminMCPConfig, falling back to PUBLIC_BASE_URL.

import Core
import Vapor

/// Resolved OAuth identifiers + endpoint URLs for the admin MCP surface.
struct AdminMCPEndpoints {
    let issuer: String
    let resource: String
    /// Origin (scheme://host[:port], no trailing slash) the well-known endpoints
    /// are served from.
    let metadataOrigin: String

    /// RFC 9728 path-based metadata URL for the admin resource — distinct from
    /// the content surface's root `…/.well-known/oauth-protected-resource`.
    var resourceMetadataURL: String {
        metadataOrigin + "/.well-known/oauth-protected-resource/admin-mcp"
    }

    /// Resolves identifiers from explicit config, falling back to
    /// `PUBLIC_BASE_URL`.  Returns nil when neither issuer nor resource can be
    /// determined — the surface cannot mount safely without them.
    static func resolve(
        adminMCP: AdminMCPConfig, security: AppSecurityConfiguration
    ) -> AdminMCPEndpoints? {
        let base = security.publicBaseURL?.absoluteString.adminTrimmedTrailingSlash
        guard let issuer = adminMCP.issuer?.adminTrimmedTrailingSlash ?? base else { return nil }
        guard let resource = adminMCP.resource ?? base.map({ $0 + "/admin-mcp" }) else { return nil }
        return AdminMCPEndpoints(issuer: issuer, resource: resource, metadataOrigin: base ?? issuer)
    }
}

/// Registers the admin MCP endpoint + discovery metadata when ADMIN_MCP_MODE is
/// mounted; a no-op otherwise.  Called from `routes(_:)`.
func registerAdminMCPRoutes(_ app: Application) throws {
    let admin = app.appConfig.adminMCP
    guard admin.mode.isMounted else { return }
    guard let endpoints = AdminMCPEndpoints.resolve(adminMCP: admin, security: app.appConfig.security)
    else {
        let mode = admin.mode.rawValue
        app.logger.warning(
            "ADMIN_MCP_MODE=\(mode) but no issuer/resource could be resolved (set ADMIN_MCP_ISSUER/ADMIN_MCP_RESOURCE or PUBLIC_BASE_URL); /admin-mcp not mounted."
        )
        return
    }

    // Reuse the content surface's production fail-safe: refuse to mount with the
    // DNS-rebinding guards left open in production unless explicitly overridden.
    if let refusal = mcpTransportGuardRefusal(
        environment: app.environment,
        allowedHosts: admin.allowedHosts,
        allowedOrigins: admin.allowedOrigins,
        allowOpenGuards: admin.allowOpenTransportGuards)
    {
        app.logger.error("admin-mcp: \(refusal)")
        return
    }
    if let warning = mcpAllowlistWarning(
        environment: app.environment,
        allowedHosts: admin.allowedHosts,
        allowedOrigins: admin.allowedOrigins)
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
        allowedHosts: admin.allowedHosts,
        allowedOrigins: admin.allowedOrigins,
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
            endpoints: endpoints, advertisedScopes: admin.mode.advertisedScopes))

    app.logger.info(
        "Admin MCP endpoint mounted at /admin-mcp — issuer=\(endpoints.issuer), resource=\(endpoints.resource)"
    )
}

private extension String {
    var adminTrimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

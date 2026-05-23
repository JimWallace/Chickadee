// APIServer/MCP/Transport/MCPServerRegistration.swift
//
// Wires the content-authoring MCP server into the live application when
// `appConfig.mcp.enabled`.  Mounts the bearer-gated /mcp transport plus the
// unauthenticated OAuth discovery endpoints, resolving the issuer/resource
// identifiers from MCPConfig (falling back to PUBLIC_BASE_URL).  The signing
// key authority itself is loaded asynchronously at startup (see runAPIServer).

import Core
import Vapor

/// The tools exposed over MCP — read + write content-authoring tools only.
/// Nothing here touches student data, grades, enrolment, or administration.
enum MCPToolCatalog {
    static var live: ToolRegistry {
        ToolRegistry([
            ListAssignmentsTool().erased(),
            UpdateAssignmentTitleTool().erased(),
        ])
    }
}

/// Resolved OAuth identifiers for the MCP resource server.
struct MCPEndpoints {
    let issuer: String
    let resource: String
    let resourceMetadataURL: String

    /// Resolves the identifiers from explicit config, falling back to
    /// `PUBLIC_BASE_URL`.  Returns nil when neither issuer nor resource can be
    /// determined — MCP cannot be mounted safely without them.
    static func resolve(mcp: MCPConfig, security: AppSecurityConfiguration) -> MCPEndpoints? {
        let base = security.publicBaseURL?.absoluteString.trimmedTrailingSlash
        guard let issuer = mcp.issuer?.trimmedTrailingSlash ?? base else { return nil }
        guard let resource = mcp.resource ?? base.map({ $0 + "/mcp" }) else { return nil }
        // Protected-resource metadata lives on the resource-server origin.
        let metadataOrigin = base ?? issuer
        return MCPEndpoints(
            issuer: issuer,
            resource: resource,
            resourceMetadataURL: metadataOrigin + "/.well-known/oauth-protected-resource"
        )
    }
}

/// Registers the MCP endpoint + discovery metadata when MCP is enabled; a no-op
/// otherwise.  Called from `routes(_:)`.
func registerMCPRoutes(_ app: Application) throws {
    let mcp = app.appConfig.mcp
    guard mcp.enabled else { return }
    guard let endpoints = MCPEndpoints.resolve(mcp: mcp, security: app.appConfig.security) else {
        app.logger.warning(
            "MCP_ENABLED=true but no issuer/resource could be resolved (set MCP_ISSUER/MCP_RESOURCE or PUBLIC_BASE_URL); /mcp not mounted."
        )
        return
    }

    let dispatcher = MCPDispatcher(
        serverInfo: MCPServerInfo(name: "Chickadee MCP", version: ChickadeeVersion.current),
        tools: MCPToolCatalog.live
    )
    let routeConfiguration = MCPRoutes.Configuration(
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins,
        resourceMetadataURL: endpoints.resourceMetadataURL
    )
    let bearer = MCPBearerAuthMiddleware(
        expectedIssuer: endpoints.issuer,
        expectedAudience: endpoints.resource,
        resourceMetadataURL: endpoints.resourceMetadataURL
    )

    try app.grouped(bearer).register(
        collection: MCPRoutes(dispatcher: dispatcher, configuration: routeConfiguration))
    try app.register(
        collection: MCPMetadataRoutes(issuer: endpoints.issuer, resource: endpoints.resource))

    app.logger.info(
        "MCP endpoint mounted at /mcp — issuer=\(endpoints.issuer), resource=\(endpoints.resource)")
}

private extension String {
    /// Drops a single trailing "/" so URL joins don't produce "//".
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

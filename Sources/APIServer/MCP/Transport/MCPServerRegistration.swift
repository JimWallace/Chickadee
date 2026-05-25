// APIServer/MCP/Transport/MCPServerRegistration.swift
//
// Wires the content-authoring MCP server into the live application when
// `appConfig.mcp.mode` is mounted (read_only or read_write).  Mounts the
// bearer-gated /mcp transport, the
// unauthenticated OAuth discovery endpoints, and (Phase 2) the browser OAuth
// flow (/oauth/authorize + /oauth/token).  Issuer/resource are resolved from
// MCPConfig, falling back to PUBLIC_BASE_URL.  The signing-key authority itself
// is loaded asynchronously at startup (see runAPIServer).

import CSRF
import Core
import Vapor

/// The tools exposed over MCP — read + write content-authoring tools only.
/// Nothing here touches student data, grades, enrolment, or administration.
enum MCPToolCatalog {
    static var live: ToolRegistry {
        ToolRegistry([
            ListCoursesTool().erased(),
            ListAssignmentsTool().erased(),
            GetAssignmentTool().erased(),
            GetSuiteTool().erased(),
            GetNotebookTool().erased(),
            ValidateAssignmentTool().erased(),
            UpdateAssignmentTool().erased(),
            UpdateSuiteTool().erased(),
            UpdatePatternFamilyTool().erased(),
            UpdateNotebookTool().erased(),
            CloneAssignmentTool().erased(),
            CreateAssignmentTool().erased(),
        ])
    }
}

/// Resolved OAuth identifiers + endpoint URLs for the MCP server.  All
/// discovery/flow endpoints live on the resource-server origin
/// (`metadataOrigin`), which equals the issuer in the common single-origin
/// deployment.
struct MCPEndpoints {
    let issuer: String
    let resource: String
    /// Origin (scheme://host[:port], no trailing slash) the well-known +
    /// /oauth/* endpoints are served from.
    let metadataOrigin: String

    var resourceMetadataURL: String { metadataOrigin + "/.well-known/oauth-protected-resource" }
    var authorizationServerMetadataURL: String { metadataOrigin + "/.well-known/oauth-authorization-server" }
    var jwksURL: String { metadataOrigin + "/.well-known/jwks.json" }
    var authorizationEndpoint: String { metadataOrigin + "/oauth/authorize" }
    var tokenEndpoint: String { metadataOrigin + "/oauth/token" }
    var registrationEndpoint: String { metadataOrigin + "/oauth/register" }

    /// Resolves the identifiers from explicit config, falling back to
    /// `PUBLIC_BASE_URL`.  Returns nil when neither issuer nor resource can be
    /// determined — MCP cannot be mounted safely without them.
    static func resolve(mcp: MCPConfig, security: AppSecurityConfiguration) -> MCPEndpoints? {
        let base = security.publicBaseURL?.absoluteString.trimmedTrailingSlash
        guard let issuer = mcp.issuer?.trimmedTrailingSlash ?? base else { return nil }
        guard let resource = mcp.resource ?? base.map({ $0 + "/mcp" }) else { return nil }
        return MCPEndpoints(issuer: issuer, resource: resource, metadataOrigin: base ?? issuer)
    }
}

/// Registers the MCP endpoint + discovery metadata when MCP is enabled; a no-op
/// otherwise.  Called from `routes(_:)`.
func registerMCPRoutes(_ app: Application) throws {
    let mcp = app.appConfig.mcp
    guard mcp.mode.isMounted else { return }
    guard let endpoints = MCPEndpoints.resolve(mcp: mcp, security: app.appConfig.security) else {
        app.logger.warning(
            "MCP_MODE=\(mcp.mode.rawValue) but no issuer/resource could be resolved (set MCP_ISSUER/MCP_RESOURCE or PUBLIC_BASE_URL); /mcp not mounted."
        )
        return
    }

    let dispatcher = MCPDispatcher(
        serverInfo: MCPServerInfo(
            name: "Chickadee MCP", version: ChickadeeVersion.current,
            title: "Chickadee Content Authoring"),
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
    try app.register(collection: MCPMetadataRoutes(endpoints: endpoints))

    app.logger.info(
        "MCP endpoint mounted at /mcp — issuer=\(endpoints.issuer), resource=\(endpoints.resource)")
}

/// Registers the Phase-2 browser OAuth flow when MCP is enabled: the consent
/// `/oauth/authorize` (session + CSRF guarded) and the machine `/oauth/token`
/// (no session/CSRF — a back-channel call from the agent).  A no-op otherwise.
func registerMCPOAuthRoutes(
    _ app: Application, sessionAuth: UserSessionAuthenticator, csrf: CSRF
) throws {
    let mcp = app.appConfig.mcp
    guard mcp.mode.isMounted,
        let endpoints = MCPEndpoints.resolve(mcp: mcp, security: app.appConfig.security)
    else { return }

    let oauth = MCPOAuthRoutes(
        endpoints: endpoints,
        accessTokenTTLSeconds: mcp.accessTokenTTLSeconds,
        grantTTLDays: mcp.grantTTLDays,
        maxRegisteredClients: mcp.maxRegisteredClients,
        maxRedirectURIsPerClient: mcp.maxRedirectURIsPerClient
    )
    // Consent UI: needs a logged-in human + a CSRF-protected form.
    let userFacing = app.grouped(sessionAuth, csrf)
    userFacing.get("oauth", "authorize", use: oauth.authorizeForm)
    userFacing.post("oauth", "authorize", use: oauth.authorizeSubmit)
    // Token + revoke + register: back-channel POSTs — no session, no CSRF, but
    // rate-limited per IP since they're unauthenticated (register is open).
    let limiter = MCPOAuthRateLimitMiddleware(
        perMinute: mcp.oauthRateLimitPerMin,
        trustForwardedFor: app.loginRateLimitConfiguration.trustForwardedFor
    )
    let backChannel = app.grouped(limiter)
    backChannel.post("oauth", "token", use: oauth.token)
    backChannel.post("oauth", "revoke", use: oauth.revoke)
    backChannel.post("oauth", "register", use: oauth.register)

    app.logger.info(
        "MCP browser OAuth flow mounted at /oauth/{authorize,token,revoke,register}")
}

private extension String {
    /// Drops a single trailing "/" so URL joins don't produce "//".
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

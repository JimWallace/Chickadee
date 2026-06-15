// APIServer/MCP/Transport/MCPServerRegistration.swift
//
// Wires the content-authoring MCP server into the live application when
// `appConfig.mcp.mode` is mounted (read_only or read_write).  Mounts the
// bearer-gated /mcp transport, the
// unauthenticated OAuth discovery endpoints, and (Phase 2) the browser OAuth
// flow (/oauth/authorize + /oauth/token).  Issuer/resource are resolved from
// MCPConfig, falling back to PUBLIC_BASE_URL.  The signing-key authority itself
// is loaded asynchronously at startup (see runAPIServer).

import Core
import Vapor

/// The tools exposed over MCP — read + write content-authoring tools only.
/// Nothing here touches student data, grades, enrolment, or administration.
enum MCPToolCatalog {
    static var live: ToolRegistry {
        ToolRegistry([
            ListCoursesTool().erased(),
            GetServerInfoTool().erased(),
            ListAssignmentsTool().erased(),
            ListCourseSectionsTool().erased(),
            GetAssignmentTool().erased(),
            GetSuiteTool().erased(),
            GetNotebookTool().erased(),
            GetSolutionTool().erased(),
            GetSupportFilesTool().erased(),
            GetGlobalInputsTool().erased(),
            PreviewPersonalizationTool().erased(),
            ValidateAssignmentTool().erased(),
            GetValidationResultTool().erased(),
            UpdateAssignmentTool().erased(),
            SetGradingModeTool().erased(),
            UpdateSuiteTool().erased(),
            UpdateGlobalInputsTool().erased(),
            UpdateSectionVariablesTool().erased(),
            CreateSuiteSectionTool().erased(),
            RenameSuiteSectionTool().erased(),
            DeleteSuiteSectionTool().erased(),
            MoveSuiteItemTool().erased(),
            UpdatePatternFamilyTool().erased(),
            CreatePatternFamilyTool().erased(),
            DeleteSuiteItemTool().erased(),
            AuthorNotebookCheckTool().erased(),
            UpdateNotebookTool().erased(),
            UpdateSolutionTool().erased(),
            AuthorScriptTool().erased(),
            CreateCourseSectionTool().erased(),
            RenameCourseSectionTool().erased(),
            DeleteCourseSectionTool().erased(),
            ReorderCourseSectionsTool().erased(),
            SetAssignmentCourseSectionTool().erased(),
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

    // Fail safe: in production, refuse to mount the transport with the
    // DNS-rebinding guards left open, unless an operator has explicitly opted in
    // (e.g. a trusted proxy pins Host/Origin).
    if let refusal = mcpTransportGuardRefusal(
        environment: app.environment,
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins,
        allowOpenGuards: mcp.allowOpenTransportGuards)
    {
        app.logger.error("\(refusal)")
        return
    }
    if let warning = mcpAllowlistWarning(
        environment: app.environment,
        allowedHosts: mcp.allowedHosts,
        allowedOrigins: mcp.allowedOrigins)
    {
        app.logger.warning("\(warning)")
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
    try app.register(
        collection: MCPMetadataRoutes(endpoints: endpoints, advertisedScopes: mcp.mode.advertisedScopes))

    app.logger.info(
        "MCP endpoint mounted at /mcp — issuer=\(endpoints.issuer), resource=\(endpoints.resource)")
}

/// Registers the Phase-2 browser OAuth flow when MCP is enabled: the consent
/// `GET /oauth/authorize` (session-guarded, mints a single-use consent token)
/// plus the back-channel POSTs — the consent submit (guarded by that token, not
/// a cookie) and the machine `/oauth/token`/`/revoke`/`/register`.  A no-op
/// otherwise.
func registerMCPOAuthRoutes(
    _ app: Application, sessionAuth: UserSessionAuthenticator
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
    // Consent screen (GET): needs the logged-in human so we can mint a
    // consent token bound to them. The submit is handled separately below.
    let consentForm = app.grouped(sessionAuth)
    consentForm.get("oauth", "authorize", use: oauth.authorizeForm)
    // Back-channel POSTs — rate-limited per IP, no session/CSRF middleware:
    //   • /authorize submit is guarded by the single-use consent token (not a
    //     cookie), so it survives Safari/ITP dropping the cross-site cookie;
    //   • /token, /revoke, /register are machine calls from the agent.
    let limiter = MCPOAuthRateLimitMiddleware(
        perMinute: mcp.oauthRateLimitPerMin,
        trustForwardedFor: app.loginRateLimitConfiguration.trustForwardedFor
    )
    let backChannel = app.grouped(limiter)
    backChannel.post("oauth", "authorize", use: oauth.authorizeSubmit)
    backChannel.post("oauth", "token", use: oauth.token)
    backChannel.post("oauth", "revoke", use: oauth.revoke)
    backChannel.post("oauth", "register", use: oauth.register)

    app.logger.info(
        "MCP browser OAuth flow mounted at /oauth/{authorize,token,revoke,register}")
}

/// The DNS-rebinding guard env-var names that are unset (empty allowlist means
/// "allow any" — see MCPRoutes.Configuration).
func mcpUnsetGuardNames(allowedHosts: Set<String>, allowedOrigins: Set<String>) -> [String] {
    var unset: [String] = []
    if allowedHosts.isEmpty { unset.append("MCP_ALLOWED_HOSTS") }
    if allowedOrigins.isEmpty { unset.append("MCP_ALLOWED_ORIGINS") }
    return unset
}

/// The operator-facing warning to log when the MCP transport is being mounted
/// in production with one or both DNS-rebinding guards disabled.  Nil when both
/// are configured, or in non-production environments where empty allowlists
/// are the normal development default.  (When the guards are open in production
/// *without* the `allowOpenGuards` override, `mcpTransportGuardRefusal` blocks
/// the mount before this warning would ever apply.)
func mcpAllowlistWarning(
    environment: Environment, allowedHosts: Set<String>, allowedOrigins: Set<String>
) -> String? {
    guard environment == .production else { return nil }
    let unset = mcpUnsetGuardNames(allowedHosts: allowedHosts, allowedOrigins: allowedOrigins)
    guard !unset.isEmpty else { return nil }
    return "MCP transport mounted with \(unset.joined(separator: " and ")) unset — "
        + "the Host/Origin DNS-rebinding guards are disabled. Set them to this "
        + "deployment's public host and origin."
}

/// The reason to REFUSE mounting `/mcp`: production, a guard left open, and no
/// explicit `MCP_ALLOW_OPEN_GUARDS` override.  Nil means it is safe to mount
/// (possibly still emitting `mcpAllowlistWarning` when overridden).  Outside
/// production, or with the override set, an open guard is allowed.
func mcpTransportGuardRefusal(
    environment: Environment, allowedHosts: Set<String>, allowedOrigins: Set<String>,
    allowOpenGuards: Bool
) -> String? {
    guard environment == .production, !allowOpenGuards else { return nil }
    let unset = mcpUnsetGuardNames(allowedHosts: allowedHosts, allowedOrigins: allowedOrigins)
    guard !unset.isEmpty else { return nil }
    return "Refusing to mount /mcp: \(unset.joined(separator: " and ")) unset in production. "
        + "The Host/Origin DNS-rebinding guards must be configured, or set "
        + "MCP_ALLOW_OPEN_GUARDS=true if a trusted reverse proxy pins Host/Origin."
}

private extension String {
    /// Drops a single trailing "/" so URL joins don't produce "//".
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

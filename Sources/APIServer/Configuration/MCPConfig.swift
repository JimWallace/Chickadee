// APIServer/Configuration/MCPConfig.swift
//
// Environment-variable knobs for the content-authoring MCP server (the /mcp
// endpoint and its OAuth 2.1 bearer auth).  Part of the AppConfig tree; read
// once at startup.  The endpoint is off by default — an operator opts in with
// MCP_MODE=read_only (inspection without write) or MCP_MODE=read_write (full
// content authoring) once auth is configured.

struct MCPConfig: Sendable {
    /// Operating mode for the `/mcp` endpoint: `off` (not mounted),
    /// `read_only` (mounted, `content:write` never honored), or `read_write`
    /// (full).  Default `off`.
    var mode: MCPMode
    /// Permitted `Host` header values for `/mcp` (DNS-rebinding mitigation).
    /// Empty means "allow any" — development only.
    var allowedHosts: Set<String>
    /// Permitted `Origin` header values for `/mcp`.  Empty means "allow any".
    var allowedOrigins: Set<String>
    /// Lifetime of an admin-minted (Phase 1) access token, in seconds.
    /// Default 24h.  Browser-flow access tokens use `accessTokenTTLSeconds`.
    var tokenTTLSeconds: Int
    /// Path of the persisted ES256 signing key; auto-generated on first start
    /// if absent (like the worker secret).
    var signingKeyPath: String
    /// Explicit token issuer (`iss`).  When nil, derived at startup from
    /// `PUBLIC_BASE_URL`.
    var issuer: String?
    /// Explicit resource identifier / expected audience (`aud`, RFC 8707).
    /// When nil, derived at startup as `PUBLIC_BASE_URL` + "/mcp".
    var resource: String?
    /// Lifetime of a browser-flow (Phase 2) access token, in seconds.  Kept
    /// short — the agent silently refreshes — so revoking a grant takes effect
    /// quickly.  Default 10 minutes.
    var accessTokenTTLSeconds: Int
    /// Lifetime of a browser-flow authorization grant (refresh-token validity),
    /// in days — "authorize once, works for a term".  Default 120 days.
    var grantTTLDays: Int
    /// Max POSTs to the back-channel OAuth endpoints (/oauth/token,/revoke,
    /// /register) per IP per minute.  Default 30.
    var oauthRateLimitPerMin: Int
    /// Cap on the total number of dynamically-registered OAuth clients, a
    /// backstop against `/oauth/register` flooding.  Default 1000.
    var maxRegisteredClients: Int
    /// Cap on `redirect_uris` accepted in a single registration.  Default 5.
    var maxRedirectURIsPerClient: Int

    init(
        mode: MCPMode,
        allowedHosts: Set<String>,
        allowedOrigins: Set<String>,
        tokenTTLSeconds: Int,
        signingKeyPath: String,
        issuer: String?,
        resource: String?,
        accessTokenTTLSeconds: Int = 600,
        grantTTLDays: Int = 120,
        oauthRateLimitPerMin: Int = 30,
        maxRegisteredClients: Int = 1000,
        maxRedirectURIsPerClient: Int = 5
    ) {
        self.mode = mode
        self.allowedHosts = allowedHosts
        self.allowedOrigins = allowedOrigins
        self.tokenTTLSeconds = tokenTTLSeconds
        self.signingKeyPath = signingKeyPath
        self.issuer = issuer
        self.resource = resource
        self.accessTokenTTLSeconds = accessTokenTTLSeconds
        self.grantTTLDays = grantTTLDays
        self.oauthRateLimitPerMin = oauthRateLimitPerMin
        self.maxRegisteredClients = maxRegisteredClients
        self.maxRedirectURIsPerClient = maxRedirectURIsPerClient
    }

    static func fromEnvironment(workDir: String) -> MCPConfig {
        MCPConfig(
            mode: MCPMode.parse(trimmedEnv("MCP_MODE")),
            allowedHosts: parseSSOIdentityAllowlist(trimmedEnv("MCP_ALLOWED_HOSTS")),
            allowedOrigins: parseSSOIdentityAllowlist(trimmedEnv("MCP_ALLOWED_ORIGINS")),
            tokenTTLSeconds: environmentInt("MCP_TOKEN_TTL_SECONDS") ?? 86_400,
            signingKeyPath: trimmedEnv("MCP_SIGNING_KEY_PATH") ?? (workDir + ".mcp-signing-key"),
            issuer: trimmedEnv("MCP_ISSUER"),
            resource: trimmedEnv("MCP_RESOURCE"),
            accessTokenTTLSeconds: environmentInt("MCP_ACCESS_TOKEN_TTL_SECONDS") ?? 600,
            grantTTLDays: environmentInt("MCP_GRANT_TTL_DAYS") ?? 120,
            oauthRateLimitPerMin: max(1, environmentInt("MCP_OAUTH_RATE_LIMIT_PER_MIN") ?? 30),
            maxRegisteredClients: max(1, environmentInt("MCP_MAX_REGISTERED_CLIENTS") ?? 1000),
            maxRedirectURIsPerClient: max(1, environmentInt("MCP_MAX_REDIRECT_URIS") ?? 5)
        )
    }

    /// All-defaults config (off, allow-any guards) for tests and the lazy
    /// `Application.appConfig` fallback.
    static let `default` = MCPConfig(
        mode: .off,
        allowedHosts: [],
        allowedOrigins: [],
        tokenTTLSeconds: 86_400,
        signingKeyPath: ".mcp-signing-key",
        issuer: nil,
        resource: nil
    )
}

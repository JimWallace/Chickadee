// APIServer/Configuration/AdminMCPConfig.swift
//
// Environment-variable knobs for the admin diagnostic MCP server (the
// /admin/mcp endpoint and its OAuth 2.1 bearer auth).  Part of the AppConfig
// tree; read once at startup.  Mirrors MCPConfig (the content surface) but is a
// separate type with its own env namespace, audience, and signing key so the two
// surfaces stay isolated (docs/admin-mcp.md §3).  Off by default — an operator
// opts in with ADMIN_MCP_MODE=read_only.
//
// Scope of this struct grows by slice: `mode` (and the transport guards) are
// used by the mount; the OAuth/issuer fields land with the browser consent flow.

struct AdminMCPConfig: Sendable {
    /// Operating mode for the `/admin/mcp` endpoint: `off` (not mounted) or
    /// `read_only`.  Default `off`.
    var mode: AdminMCPMode
    /// Permitted `Host` header values for `/admin/mcp` (DNS-rebinding
    /// mitigation).  Empty means "allow any" — development only.
    var allowedHosts: Set<String>
    /// Permitted `Origin` header values for `/admin/mcp`.  Empty means "allow any".
    var allowedOrigins: Set<String>
    /// Path of the persisted ES256 signing key for admin tokens; auto-generated
    /// on first start if absent.  Separate from the content surface's key so
    /// rotating it revokes admin tokens without touching content grants.
    var signingKeyPath: String
    /// Explicit token issuer (`iss`).  When nil, derived at startup from
    /// `PUBLIC_BASE_URL`.
    var issuer: String?
    /// Explicit resource identifier / expected audience (`aud`, RFC 8707).
    /// When nil, derived at startup as `PUBLIC_BASE_URL` + "/admin-mcp".  Distinct
    /// from the content resource so a content token can't call admin tools.  Note
    /// the path is "/admin-mcp", NOT "/admin/mcp" — the latter is already the
    /// admin web page that manages content-MCP service accounts.
    var resource: String?
    /// Lifetime of a browser-flow access token, in seconds.  Default 10 minutes.
    var accessTokenTTLSeconds: Int
    /// Allow `/admin/mcp` to mount in production even when the Host/Origin
    /// DNS-rebinding guards are empty.  Default false.
    var allowOpenTransportGuards: Bool

    init(
        mode: AdminMCPMode,
        allowedHosts: Set<String>,
        allowedOrigins: Set<String>,
        signingKeyPath: String,
        issuer: String?,
        resource: String?,
        accessTokenTTLSeconds: Int = 600,
        allowOpenTransportGuards: Bool = false
    ) {
        self.mode = mode
        self.allowedHosts = allowedHosts
        self.allowedOrigins = allowedOrigins
        self.signingKeyPath = signingKeyPath
        self.issuer = issuer
        self.resource = resource
        self.accessTokenTTLSeconds = accessTokenTTLSeconds
        self.allowOpenTransportGuards = allowOpenTransportGuards
    }

    static func fromEnvironment(workDir: String) -> AdminMCPConfig {
        AdminMCPConfig(
            mode: AdminMCPMode.parse(trimmedEnv("ADMIN_MCP_MODE")),
            allowedHosts: parseSSOIdentityAllowlist(trimmedEnv("ADMIN_MCP_ALLOWED_HOSTS")),
            allowedOrigins: parseSSOIdentityAllowlist(trimmedEnv("ADMIN_MCP_ALLOWED_ORIGINS")),
            signingKeyPath: trimmedEnv("ADMIN_MCP_SIGNING_KEY_PATH")
                ?? (workDir + ".admin-mcp-signing-key"),
            issuer: trimmedEnv("ADMIN_MCP_ISSUER"),
            resource: trimmedEnv("ADMIN_MCP_RESOURCE"),
            accessTokenTTLSeconds: environmentInt("ADMIN_MCP_ACCESS_TOKEN_TTL_SECONDS") ?? 600,
            allowOpenTransportGuards: environmentBool("ADMIN_MCP_ALLOW_OPEN_GUARDS") ?? false
        )
    }

    /// All-defaults config (off, allow-any guards) for tests and the lazy
    /// `Application.appConfig` fallback.
    static let `default` = AdminMCPConfig(
        mode: .off,
        allowedHosts: [],
        allowedOrigins: [],
        signingKeyPath: ".admin-mcp-signing-key",
        issuer: nil,
        resource: nil
    )
}

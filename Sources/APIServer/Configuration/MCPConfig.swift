// APIServer/Configuration/MCPConfig.swift
//
// Environment-variable knobs for the content-authoring MCP server (the /mcp
// endpoint and its OAuth 2.1 bearer auth).  Part of the AppConfig tree; read
// once at startup.  The endpoint is disabled by default — an operator opts in
// with MCP_ENABLED=true once auth is configured.

struct MCPConfig: Sendable {
    /// Whether the `/mcp` endpoint is mounted on the live app.  Default false.
    var enabled: Bool
    /// Permitted `Host` header values for `/mcp` (DNS-rebinding mitigation).
    /// Empty means "allow any" — development only.
    var allowedHosts: Set<String>
    /// Permitted `Origin` header values for `/mcp`.  Empty means "allow any".
    var allowedOrigins: Set<String>
    /// Lifetime of an admin-minted access token, in seconds.  Default 24h.
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

    static func fromEnvironment(workDir: String) -> MCPConfig {
        MCPConfig(
            enabled: environmentBool("MCP_ENABLED") ?? false,
            allowedHosts: parseSSOIdentityAllowlist(trimmedEnv("MCP_ALLOWED_HOSTS")),
            allowedOrigins: parseSSOIdentityAllowlist(trimmedEnv("MCP_ALLOWED_ORIGINS")),
            tokenTTLSeconds: environmentInt("MCP_TOKEN_TTL_SECONDS") ?? 86_400,
            signingKeyPath: trimmedEnv("MCP_SIGNING_KEY_PATH") ?? (workDir + ".mcp-signing-key"),
            issuer: trimmedEnv("MCP_ISSUER"),
            resource: trimmedEnv("MCP_RESOURCE")
        )
    }

    /// All-defaults config (disabled, allow-any guards) for tests and the lazy
    /// `Application.appConfig` fallback.
    static let `default` = MCPConfig(
        enabled: false,
        allowedHosts: [],
        allowedOrigins: [],
        tokenTTLSeconds: 86_400,
        signingKeyPath: ".mcp-signing-key",
        issuer: nil,
        resource: nil
    )
}

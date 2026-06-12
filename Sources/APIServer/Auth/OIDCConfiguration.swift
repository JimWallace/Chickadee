// APIServer/Auth/OIDCConfiguration.swift
//
// OIDC discovery + runtime configuration.
// Loaded once at startup (from main()) and stored in app.oidcConfig.
//
// Environment variables:
//   OIDC_AUTH_SERVER      — auth server base URL used for discovery
//   OIDC_CLIENT_ID        — required when AUTH_MODE is 'sso' or 'dual'
//   OIDC_CLIENT_SECRET    — required when AUTH_MODE is 'sso' or 'dual'
//   OIDC_CALLBACK         — callback path (default: /auth/sso/callback)
//   OIDC_USERNAME_CLAIM   — JWT claim used as the Chickadee username
//                           (default: "preferred_username")
//   OIDC_EMAIL_CLAIM      — JWT claim used as the email address
//                           (default: "email")

import Foundation
import JWT
import Vapor

// MARK: - OIDC Discovery Response

/// Decoded from the IdP's /.well-known/openid-configuration endpoint.
struct OIDCDiscovery: Codable, Sendable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let jwksURI: String
    /// RFC 7009 token revocation endpoint (optional — not all providers publish this).
    let revocationEndpoint: String?
    /// OIDC RP-Initiated Logout end-session endpoint (optional).
    let endSessionEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
        case endSessionEndpoint = "end_session_endpoint"
    }
}

// MARK: - Token Endpoint Response

/// Decoded from the IdP's token endpoint after code exchange.
struct OIDCTokenResponse: Codable, Sendable {
    let accessToken: String
    let idToken: String
    let tokenType: String
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Runtime Configuration

// MARK: - Claim configuration

/// Which JWT claim names to use for user identity fields.
/// Built from `OIDCEnvConfig`; defaults match standard OIDC claims.
struct OIDCClaimConfig: Sendable {
    /// JWT claim used as the Chickadee username. Default: `preferred_username`.
    /// UWaterloo DUO: set to `winaccountname`.
    let usernameClaim: String

    /// JWT claim used as the email address. Default: `email`.
    let emailClaim: String

    init(
        usernameClaim: String = "preferred_username",
        emailClaim: String = "email"
    ) {
        self.usernameClaim = usernameClaim
        self.emailClaim = emailClaim
    }
}

// MARK: - Runtime Configuration

/// Resolved OIDC configuration, stored in app.oidcConfig after startup.
struct OIDCConfiguration: Sendable {
    let clientID: String
    let clientSecret: String
    /// The absolute redirect URI registered with the IdP.
    let redirectURI: String
    let discovery: OIDCDiscovery
    let claimConfig: OIDCClaimConfig

    // MARK: Startup loader

    /// Reads env vars, fetches the DUO OIDC discovery document, loads JWKS into
    /// app.jwt.keys, and returns a ready-to-use configuration.
    ///
    /// Throws `Abort(.internalServerError)` if required env vars are missing or
    /// if either network request fails. Intended to be called once from `main()`
    /// before the server begins serving requests.
    static func load(from app: Application) async throws -> OIDCConfiguration {
        let env = app.appConfig.oidc
        guard let clientID = env.clientID else {
            throw Abort(
                .internalServerError,
                reason: "OIDC_CLIENT_ID is required when AUTH_MODE is not 'local'"
            )
        }

        guard let clientSecret = env.clientSecret else {
            throw Abort(
                .internalServerError,
                reason: "OIDC_CLIENT_SECRET is required when AUTH_MODE is not 'local'"
            )
        }

        // Honour `app.securityConfiguration` (legacy accessor with a per-test
        // override path) before falling back to `appConfig.security`, so tests
        // that set `app.securityConfiguration = ...` directly still steer the
        // redirect URI.
        let baseURL =
            app.securityConfiguration.publicBaseURL?.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? "http://localhost:8080"
        let redirectURI = baseURL + env.callbackPath

        let discoveryURL: String = {
            if let configured = env.authServerOverride {
                let trimmed = configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if trimmed.hasSuffix(".well-known/openid-configuration") {
                    return trimmed
                }
                return trimmed + "/.well-known/openid-configuration"
            }
            return "https://sso-4ccc589b.sso.duosecurity.com/oidc/\(clientID)/.well-known/openid-configuration"
        }()

        // Defense in depth against a fat-fingered OIDC_AUTH_SERVER pointing
        // at an internal service or going out over plain HTTP.  Operator-
        // settable, so not strictly a remote-attacker SSRF, but the failure
        // mode without this check (server happily fetches from
        // http://localhost:6379) is bad enough that failing loud at
        // startup beats a confusing runtime error.
        try validateOIDCDiscoveryURL(discoveryURL, allowInsecure: env.allowInsecure)

        app.logger.info("Fetching OIDC discovery document: \(discoveryURL)")
        let discoveryResponse = try await app.client.get(URI(string: discoveryURL))
        guard discoveryResponse.status == .ok else {
            throw Abort(
                .internalServerError,
                reason: "OIDC discovery failed: HTTP \(discoveryResponse.status.code)"
            )
        }
        let discovery = try discoveryResponse.content.decode(OIDCDiscovery.self)

        // Fetch JWKS and register keys for JWT verification
        app.logger.info("Fetching OIDC JWKS: \(discovery.jwksURI)")
        let jwksResponse = try await app.client.get(URI(string: discovery.jwksURI))
        guard jwksResponse.status == .ok else {
            throw Abort(
                .internalServerError,
                reason: "OIDC JWKS fetch failed: HTTP \(jwksResponse.status.code)"
            )
        }
        var jwksBuffer = jwksResponse.body ?? ByteBuffer()
        let jwksJSON = jwksBuffer.readString(length: jwksBuffer.readableBytes) ?? ""
        try await app.jwt.keys.add(jwksJSON: jwksJSON)

        let claimConfig = OIDCClaimConfig(
            usernameClaim: env.usernameClaim,
            emailClaim: env.emailClaim
        )
        app.logger.info(
            "OIDC configured: issuer=\(discovery.issuer), redirectURI=\(redirectURI), usernameClaim=\(claimConfig.usernameClaim), emailClaim=\(claimConfig.emailClaim)"
        )

        return OIDCConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            discovery: discovery,
            claimConfig: claimConfig
        )
    }
}

// MARK: - Discovery URL validation

enum OIDCDiscoveryURLError: Error, CustomStringConvertible {
    case malformed(url: String)
    case insecureScheme(url: String)
    case privateHost(host: String)

    var description: String {
        switch self {
        case .malformed(let url):
            return "OIDC_AUTH_SERVER is not a valid URL: \(url)"
        case .insecureScheme(let url):
            return
                "OIDC_AUTH_SERVER must use https:// (got \(url)); set OIDC_ALLOW_INSECURE=true to override (development only)"
        case .privateHost(let host):
            return
                "OIDC_AUTH_SERVER host \(host) resolves into a loopback / private IP range; set OIDC_ALLOW_INSECURE=true to override (development only)"
        }
    }
}

/// Throws if `urlString` would have the discovery fetch land on plaintext or
/// at a loopback / private-range host without an explicit `allowInsecure`
/// override.  Intentionally string-based: we don't resolve DNS here, only
/// reject hosts that are syntactically private — operators with a private
/// IdP behind a domain name continue to work as long as the hostname isn't
/// itself a private literal.
func validateOIDCDiscoveryURL(_ urlString: String, allowInsecure: Bool) throws {
    guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
        let host = url.host?.lowercased()
    else {
        throw OIDCDiscoveryURLError.malformed(url: urlString)
    }
    if !allowInsecure {
        guard scheme == "https" else {
            throw OIDCDiscoveryURLError.insecureScheme(url: urlString)
        }
        if isPrivateOrLoopbackHost(host) {
            throw OIDCDiscoveryURLError.privateHost(host: host)
        }
    }
}

private func isPrivateOrLoopbackHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if host == "0.0.0.0" { return true }
    // IPv6 loopback.
    if host == "::1" || host == "[::1]" { return true }
    // IPv4 ranges: 10/8, 127/8, 172.16/12, 192.168/16.
    let parts = host.split(separator: ".").map(String.init)
    if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
        Int(parts[2]) != nil, Int(parts[3]) != nil
    {
        if a == 10 || a == 127 { return true }
        if a == 192, b == 168 { return true }
        if a == 172, (16...31).contains(b) { return true }
        if a == 169, b == 254 { return true }  // link-local
    }
    // IPv6 unique-local fc00::/7 (literal form, post-bracket-strip).
    let trimmedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if trimmedHost.hasPrefix("fc") || trimmedHost.hasPrefix("fd") {
        // Conservative: any host starting with fc/fd that contains a colon
        // looks like an IPv6 unique-local literal.
        if trimmedHost.contains(":") { return true }
    }
    return false
}

// MARK: - Application Storage

private struct OIDCConfigurationKey: StorageKey {
    typealias Value = OIDCConfiguration
}

extension Application {
    /// The active OIDC configuration. Nil when AUTH_MODE is `.local` or before startup loading.
    var oidcConfig: OIDCConfiguration? {
        get { storage[OIDCConfigurationKey.self] }
        set { storage[OIDCConfigurationKey.self] = newValue }
    }
}

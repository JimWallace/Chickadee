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

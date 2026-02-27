// APIServer/Auth/OIDCConfiguration.swift
//
// OIDC discovery + runtime configuration for UWaterloo DUO OIDC.
// Loaded once at startup (from main()) and stored in app.oidcConfig.
//
// Environment variables:
//   OIDC_CLIENT_ID     — required when AUTH_MODE is 'sso' or 'dual'
//   OIDC_CLIENT_SECRET — required when AUTH_MODE is 'sso' or 'dual'
//
// Discovery URL pattern (DUO OIDC at UWaterloo):
//   https://sso-4ccc589b.sso.duosecurity.com/oidc/{CLIENT_ID}/.well-known/openid-configuration

import Vapor
import JWT
import Foundation

// MARK: - OIDC Discovery Response

/// Decoded from the IdP's /.well-known/openid-configuration endpoint.
struct OIDCDiscovery: Codable, Sendable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let jwksURI: String

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint         = "token_endpoint"
        case jwksURI               = "jwks_uri"
    }
}

// MARK: - Token Endpoint Response

/// Decoded from the IdP's token endpoint after code exchange.
struct OIDCTokenResponse: Codable, Sendable {
    let accessToken: String
    let idToken: String
    let tokenType: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken     = "id_token"
        case tokenType   = "token_type"
        case expiresIn   = "expires_in"
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

    // MARK: Startup loader

    /// Reads env vars, fetches the DUO OIDC discovery document, loads JWKS into
    /// app.jwt.keys, and returns a ready-to-use configuration.
    ///
    /// Throws `Abort(.internalServerError)` if required env vars are missing or
    /// if either network request fails. Intended to be called once from `main()`
    /// before the server begins serving requests.
    static func load(from app: Application) async throws -> OIDCConfiguration {
        guard
            let clientID = Environment.get("OIDC_CLIENT_ID")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !clientID.isEmpty
        else {
            throw Abort(
                .internalServerError,
                reason: "OIDC_CLIENT_ID is required when AUTH_MODE is not 'local'"
            )
        }

        guard
            let clientSecret = Environment.get("OIDC_CLIENT_SECRET")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !clientSecret.isEmpty
        else {
            throw Abort(
                .internalServerError,
                reason: "OIDC_CLIENT_SECRET is required when AUTH_MODE is not 'local'"
            )
        }

        let baseURL = app.securityConfiguration.publicBaseURL?.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? "http://localhost:8080"
        let redirectURI = baseURL + "/auth/sso/callback"

        // Fetch discovery document
        let discoveryURL = "https://sso-4ccc589b.sso.duosecurity.com/oidc/\(clientID)/.well-known/openid-configuration"
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

        app.logger.info("OIDC configured: issuer=\(discovery.issuer), redirectURI=\(redirectURI)")

        return OIDCConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            discovery: discovery
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

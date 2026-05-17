// APIServer/Configuration/OIDCEnvConfig.swift
//
// The env-only portion of OIDC configuration. The resolved configuration
// (which includes the IdP-discovered endpoints + JWKS) is built later in
// OIDCConfiguration.load(from:) using these values as input.

import Foundation
import Vapor

struct OIDCEnvConfig: Sendable {
    let clientID: String?
    let clientSecret: String?
    /// Override for the OIDC issuer / discovery base URL. When nil, the DUO
    /// per-client discovery URL is used (see OIDCConfiguration.load).
    let authServerOverride: String?
    /// Normalized callback path with leading slash (default `/auth/sso/callback`).
    let callbackPath: String
    /// JWT claim used as the Chickadee username (default `preferred_username`).
    let usernameClaim: String
    /// JWT claim used as the email address (default `email`).
    let emailClaim: String
    /// When true, `OIDC_AUTH_SERVER` accepts `http://` and private-range
    /// hosts.  Required for local-Docker IdP fixtures; off in production
    /// so a fat-fingered env var can't redirect the discovery fetch to an
    /// internal service.
    let allowInsecure: Bool

    static let `default` = OIDCEnvConfig(
        clientID: nil,
        clientSecret: nil,
        authServerOverride: nil,
        callbackPath: "/auth/sso/callback",
        usernameClaim: "preferred_username",
        emailClaim: "email",
        allowInsecure: false
    )

    static func fromEnvironment() -> OIDCEnvConfig {
        OIDCEnvConfig(
            clientID: trimmedEnv("OIDC_CLIENT_ID"),
            clientSecret: trimmedEnv("OIDC_CLIENT_SECRET"),
            authServerOverride: trimmedEnv("OIDC_AUTH_SERVER"),
            callbackPath: normalizedCallbackPath(trimmedEnv("OIDC_CALLBACK")),
            usernameClaim: trimmedEnv("OIDC_USERNAME_CLAIM") ?? "preferred_username",
            emailClaim: trimmedEnv("OIDC_EMAIL_CLAIM") ?? "email",
            allowInsecure: (trimmedEnv("OIDC_ALLOW_INSECURE")?.lowercased()).map {
                ["1", "true", "yes"].contains($0)
            } ?? false
        )
    }

    /// True when both clientID and clientSecret are configured. SSO/dual modes
    /// require this; AppConfig.fromEnvironment surfaces it as a startup warning.
    var hasCredentials: Bool {
        clientID?.isEmpty == false && clientSecret?.isEmpty == false
    }
}

private func normalizedCallbackPath(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "/auth/sso/callback" }
    return raw.hasPrefix("/") ? raw : "/" + raw
}

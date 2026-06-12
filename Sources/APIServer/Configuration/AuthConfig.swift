// APIServer/Configuration/AuthConfig.swift
//
// AUTH_MODE + non-SSO gating + SSO identity allowlists, parsed once at startup.

import Foundation
import Vapor

struct AuthConfig: Sendable {
    /// Effective auth mode after applying the non-SSO gate.
    let mode: AuthMode
    /// Raw AUTH_MODE value before non-SSO downgrade, used for the startup warning.
    let requestedMode: AuthMode?
    /// Whether non-SSO modes are explicitly enabled.
    let nonSSOModesEnabled: Bool
    /// Lowercased SSO identifiers that should be granted admin on first login.
    let ssoAdminUsers: Set<String>
    /// Lowercased SSO identifiers that should be granted instructor on first login.
    let ssoInstructorUsers: Set<String>

    static let defaultLocal = AuthConfig(
        mode: .local,
        requestedMode: .local,
        nonSSOModesEnabled: true,
        ssoAdminUsers: [],
        ssoInstructorUsers: []
    )

    static func fromEnvironment(override: AuthMode? = nil) -> AuthConfig {
        let requested = parseAuthMode()
        let nonSSO = environmentBool("ENABLE_NON_SSO_AUTH_MODES") ?? false
        let effective = override ?? resolvedAuthMode(requestedMode: requested, nonSSOModesEnabled: nonSSO)
        return AuthConfig(
            mode: effective,
            requestedMode: requested,
            nonSSOModesEnabled: nonSSO,
            ssoAdminUsers: parseSSOIdentityAllowlist(Environment.get("SSO_ADMIN_USERS")),
            ssoInstructorUsers: parseSSOIdentityAllowlist(Environment.get("SSO_INSTRUCTOR_USERS"))
        )
    }
}

enum AuthMode: String, Sendable {
    case local
    case sso
    case dual
}

private func parseAuthMode() -> AuthMode? {
    guard let raw = trimmedEnv("AUTH_MODE")?.lowercased() else { return nil }
    return AuthMode(rawValue: raw)
}

func resolvedAuthMode(requestedMode: AuthMode?, nonSSOModesEnabled: Bool) -> AuthMode {
    let requested = requestedMode ?? .sso
    guard requested != .sso else { return .sso }
    return nonSSOModesEnabled ? requested : .sso
}

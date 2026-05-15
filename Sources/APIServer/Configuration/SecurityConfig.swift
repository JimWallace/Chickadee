// APIServer/Configuration/SecurityConfig.swift
//
// HTTPS enforcement, session-cookie flags, and the SCAN_MODE seatbelt.
// `AppSecurityConfiguration` keeps its old name to avoid churn at call sites
// (HTTPSRedirectMiddleware reads `.publicBaseURL`, etc.); it now lives next to
// the other AppConfig substructs.

import Foundation
import Vapor

struct AppSecurityConfiguration: Sendable {
    let publicBaseURL: URL?
    let enforceHTTPS: Bool
    let trustForwardedProto: Bool
    let sessionCookieSecure: Bool

    static let `default` = AppSecurityConfiguration(
        publicBaseURL: nil,
        enforceHTTPS: false,
        trustForwardedProto: true,
        sessionCookieSecure: false
    )

    static func fromEnvironment(authMode: AuthMode) -> Self {
        let publicBaseURL = trimmedEnv("PUBLIC_BASE_URL").flatMap(URL.init(string:))
        let publicBaseIsHTTPS = (publicBaseURL?.scheme?.lowercased() == "https")

        return AppSecurityConfiguration(
            publicBaseURL: publicBaseURL,
            enforceHTTPS: environmentBool("ENFORCE_HTTPS") ?? (authMode != .local && publicBaseIsHTTPS),
            trustForwardedProto: environmentBool("TRUST_X_FORWARDED_PROTO") ?? true,
            sessionCookieSecure: environmentBool("SESSION_COOKIE_SECURE") ?? (publicBaseIsHTTPS || authMode != .local)
        )
    }
}

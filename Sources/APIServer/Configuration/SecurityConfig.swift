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
    /// Idle (inactivity) timeout in seconds. Zero disables the gate.
    /// Set via `SESSION_IDLE_TIMEOUT_MINUTES` (default 30 minutes).
    let sessionIdleTimeoutSeconds: TimeInterval
    /// How many seconds before the idle ceiling the client shows the
    /// "you're about to be signed out" warning. Set via
    /// `SESSION_IDLE_WARNING_SECONDS` (default 120). Clamped below the
    /// timeout; zero (or a disabled gate) suppresses the warning so the
    /// client logs out straight at the ceiling.
    let sessionIdleWarningSeconds: TimeInterval
    /// When true, the student notebook editor page AND every editor asset
    /// (the `/jupyterlite/*` documents, plus the fast-path-served
    /// `/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`, `/vendor`
    /// trees) are served with COOP + COEP (`require-corp`) so the editor is
    /// cross-origin isolated and the Pyodide kernel can use `SharedArrayBuffer`
    /// for synchronous execution. SAB removes the kernel's dependence on the
    /// JupyterLite service worker for synchronous stdin/Drive — eliminating both
    /// the main-thread freeze and the SW-control "Kernel Unknown" race (see
    /// docs/notebook-editor-kernel-boot.md). Set via
    /// `NOTEBOOK_CROSS_ORIGIN_ISOLATION`, default false: COEP on the editor page
    /// has broken the iframe before (#574), so this is gated behind a flag —
    /// enable on staging, verify the editor boots in each target browser
    /// (Chromium is covered by the editor-smoke harness; Safari is not), then
    /// enable in production, with instant rollback by flipping the flag (no
    /// redeploy).
    let notebookCrossOriginIsolation: Bool

    static let `default` = AppSecurityConfiguration(
        publicBaseURL: nil,
        enforceHTTPS: false,
        trustForwardedProto: true,
        sessionCookieSecure: false,
        sessionIdleTimeoutSeconds: 30 * 60,
        sessionIdleWarningSeconds: 120,
        notebookCrossOriginIsolation: false
    )

    static func fromEnvironment(authMode: AuthMode) -> Self {
        let publicBaseURL = trimmedEnv("PUBLIC_BASE_URL").flatMap(URL.init(string:))
        let publicBaseIsHTTPS = (publicBaseURL?.scheme?.lowercased() == "https")

        // SESSION_IDLE_TIMEOUT_MINUTES: positive integer = idle ceiling in
        // minutes; 0 or negative disables the gate. Default 30 satisfies the
        // standard institutional inactivity-logout requirement.
        let idleMinutes = environmentInt("SESSION_IDLE_TIMEOUT_MINUTES") ?? 30
        let idleSeconds = idleMinutes > 0 ? TimeInterval(idleMinutes) * 60 : 0

        // SESSION_IDLE_WARNING_SECONDS: how long before the ceiling the client
        // shows the warning modal. Default 120. Must stay strictly below the
        // timeout (we leave at least a 5 s logout window); it's meaningless
        // when the gate is disabled.
        let warningRaw = environmentInt("SESSION_IDLE_WARNING_SECONDS") ?? 120
        let warningSeconds: TimeInterval
        if idleSeconds <= 0 || warningRaw <= 0 {
            warningSeconds = 0
        } else {
            warningSeconds = min(TimeInterval(warningRaw), max(0, idleSeconds - 5))
        }

        return AppSecurityConfiguration(
            publicBaseURL: publicBaseURL,
            enforceHTTPS: environmentBool("ENFORCE_HTTPS") ?? (authMode != .local && publicBaseIsHTTPS),
            trustForwardedProto: environmentBool("TRUST_X_FORWARDED_PROTO") ?? true,
            sessionCookieSecure: environmentBool("SESSION_COOKIE_SECURE") ?? (publicBaseIsHTTPS || authMode != .local),
            sessionIdleTimeoutSeconds: idleSeconds,
            sessionIdleWarningSeconds: warningSeconds,
            notebookCrossOriginIsolation: environmentBool("NOTEBOOK_CROSS_ORIGIN_ISOLATION") ?? false
        )
    }
}

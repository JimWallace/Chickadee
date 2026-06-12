// APIServer/Configuration/WorkerConfig.swift
//
// Runner ↔ server coupling: the HMAC shared secret and the public base URL
// the server advertises to runners on poll responses.
//
// `WORKER_SHARED_SECRET` is the legacy alias for `RUNNER_SHARED_SECRET` and is
// honoured for back-compat. Primary always wins.

import Foundation
import Vapor

struct WorkerConfig: Sendable {
    /// Pre-configured shared secret, if either RUNNER_SHARED_SECRET or the
    /// legacy WORKER_SHARED_SECRET is set in the environment. May be nil — the
    /// startup-resolution logic also consults the CLI arg and the persisted
    /// `.worker-secret` file.
    let sharedSecret: String?
    /// True when the legacy `WORKER_SHARED_SECRET` was used because
    /// `RUNNER_SHARED_SECRET` was unset. AppConfig.logSummary emits a
    /// deprecation warning when this is true so operators migrate.
    let usedLegacyAlias: Bool
    /// Explicit override for the URL workers should use when calling back into
    /// the server (artifact downloads, result POSTs). When nil, the route
    /// handler derives it from forwarded headers and the bind config.
    let publicBaseURL: String?

    static let `default` = WorkerConfig(
        sharedSecret: nil,
        usedLegacyAlias: false,
        publicBaseURL: nil
    )

    static func fromEnvironment() -> WorkerConfig {
        let primary = trimmedEnv("RUNNER_SHARED_SECRET")
        let legacy = trimmedEnv("WORKER_SHARED_SECRET")
        let usedLegacy = (primary == nil) && (legacy != nil)
        let publicBaseURL = trimmedEnv("WORKER_PUBLIC_BASE_URL")
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return WorkerConfig(
            sharedSecret: primary ?? legacy,
            usedLegacyAlias: usedLegacy,
            publicBaseURL: publicBaseURL
        )
    }
}

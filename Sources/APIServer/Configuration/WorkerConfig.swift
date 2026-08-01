// APIServer/Configuration/WorkerConfig.swift
//
// Runner ↔ server coupling: the HMAC shared secret and the public base URL
// the server advertises to runners on poll responses.
//
// The secret env var is `RUNNER_SHARED_SECRET`.  (The pre-0.5 legacy alias
// `WORKER_SHARED_SECRET` was retired after a long deprecation-warning period;
// it is now ignored.)

import Foundation
import Vapor

struct WorkerConfig: Sendable {
    /// Pre-configured shared secret, if RUNNER_SHARED_SECRET is set in the
    /// environment. May be nil — the startup-resolution logic also consults
    /// the CLI arg and the persisted `.worker-secret` file.
    let sharedSecret: String?
    /// Explicit override for the URL workers should use when calling back into
    /// the server (artifact downloads, result POSTs). When nil, the route
    /// handler derives it from forwarded headers and the bind config.
    let publicBaseURL: String?

    static let `default` = WorkerConfig(
        sharedSecret: nil,
        publicBaseURL: nil
    )

    static func fromEnvironment() -> WorkerConfig {
        let publicBaseURL = trimmedEnv("WORKER_PUBLIC_BASE_URL")
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return WorkerConfig(
            sharedSecret: trimmedEnv("RUNNER_SHARED_SECRET"),
            publicBaseURL: publicBaseURL
        )
    }
}

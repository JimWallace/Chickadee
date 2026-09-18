// APIServer/Auth/OIDCConfigurationProvider.swift
//
// Holds the resolved OIDC configuration, and owns the on-demand retry that
// keeps a failed discovery fetch from stopping the server.
//
// The server used to fetch the discovery document and the JWKS in `main()`,
// before `app.execute()`, and treat any failure as fatal. That tied the
// server's ability to START to the IdP's availability. During an ADFS outage
// the already-running container stayed up on the configuration it had loaded
// earlier, but every newly built container died during startup: it never bound
// a port, so it never answered `/health`, so the blue-green gate in
// `scripts/bluegreen-deploy.sh` rejected it. The deployment could not roll
// forward at the exact moment a fix had to ship.
//
// Startup now validates the operator-supplied environment, which stays fatal
// because a missing OIDC_CLIENT_ID is a deployment error that no retry can
// correct, and then attempts the network fetch as best effort. A failed fetch
// is logged and retried when an SSO route is next used. An IdP outage makes
// SSO unavailable; it no longer prevents the server from starting.

import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Stores the resolved OIDC configuration and retries the discovery fetch on
/// demand.
///
/// Reads are synchronous because `SecurityHeadersMiddleware` needs the
/// end-session endpoint on the response path, where an actor hop would cost a
/// suspension on every response.
final class OIDCConfigurationProvider: Sendable {

    /// How long to wait after a failed fetch before another request may retry.
    ///
    /// Long enough that an unreachable IdP is not dialled once per request,
    /// short enough that the first sign-in after recovery succeeds.
    static let retryCooldown: TimeInterval = 30

    private struct State {
        var configuration: OIDCConfiguration?
        /// The fetch in progress, so concurrent callers share one attempt
        /// instead of each opening its own connection to a slow IdP.
        var inFlight: Task<OIDCConfiguration, any Error>?
        var nextRetryNotBefore: Date?
    }

    private let state = NIOLockedValueBox(State())

    /// The configuration resolved so far, or nil when none has loaded yet.
    /// Performs no I/O and never blocks.
    var current: OIDCConfiguration? {
        state.withLockedValue { $0.configuration }
    }

    /// Replaces the stored configuration. Used by startup and by tests.
    func store(_ configuration: OIDCConfiguration?) {
        state.withLockedValue { $0.configuration = configuration }
    }

    /// Returns the stored configuration, or attempts one fetch when none is
    /// stored yet.
    ///
    /// Returns nil when the fetch fails, or when a previous failure is still
    /// inside the retry cooldown. Callers treat nil as "SSO is unavailable" and
    /// degrade, so a failure here never propagates as an error.
    func resolve(app: Application, now: Date = Date()) async -> OIDCConfiguration? {
        enum Next {
            case resolved(OIDCConfiguration)
            case pending(Task<OIDCConfiguration, any Error>)
            case cooling
        }

        let next: Next = state.withLockedValue { state in
            if let configuration = state.configuration {
                return .resolved(configuration)
            }
            if let inFlight = state.inFlight {
                return .pending(inFlight)
            }
            if let notBefore = state.nextRetryNotBefore, now < notBefore {
                return .cooling
            }
            let task = Task { try await OIDCConfiguration.load(from: app) }
            state.inFlight = task
            return .pending(task)
        }

        switch next {
        case .resolved(let configuration):
            return configuration
        case .cooling:
            return nil
        case .pending(let task):
            return await complete(task, app: app)
        }
    }

    private func complete(
        _ task: Task<OIDCConfiguration, any Error>,
        app: Application
    ) async -> OIDCConfiguration? {
        do {
            let configuration = try await task.value
            state.withLockedValue { state in
                state.configuration = configuration
                state.inFlight = nil
                state.nextRetryNotBefore = nil
            }
            app.logger.info("OIDC discovery succeeded; SSO is available.")
            return configuration
        } catch {
            state.withLockedValue { state in
                state.inFlight = nil
                state.nextRetryNotBefore = Date().addingTimeInterval(Self.retryCooldown)
            }
            app.logger.warning(
                "OIDC discovery failed; SSO is unavailable until it succeeds: \(String(reflecting: error))"
            )
            return nil
        }
    }
}

// APIServer/Services/OutboundReachabilityStore.swift
//
// Records whether the server's outbound HTTP calls are reaching anything.
//
// Written after a two-day production outage in which the host's Docker iptables
// chains were destroyed by an `iptables-restore` during an unattended kernel
// upgrade. Container egress died instantly, so every new outbound connection
// timed out: SSO token exchanges and BrightSpace roster sweeps both failed from
// the same moment. The already-running process kept its established database
// connections, so the site went on serving pages and ALL SEVEN health rules
// stayed green for 38 hours.
//
// The evidence was never missing — `Token exchange failed: connectTimeout` was
// logged every few minutes throughout. Nothing turned those lines into a signal.
// This store is that aggregation, and nothing more: the call sites already knew
// whether they succeeded.

import Foundation
import Vapor

/// A coarse label for what the server was trying to reach.
///
/// Deliberately not a hostname: these labels reach alert payloads and webhooks,
/// and the configured IdP or LMS host is deployment configuration that does not
/// need to travel with a page.
enum OutboundDestination: String, Sendable {
    case identityProvider
    case brightspace

    var humanReadable: String {
        switch self {
        case .identityProvider: return "identity provider"
        case .brightspace: return "BrightSpace"
        }
    }
}

/// Tracks recent outbound attempts so a health rule can tell "the far end is
/// refusing us" from "we cannot reach anything at all".
actor OutboundReachabilityStore {

    /// How many attempts to remember. Outbound calls here are periodic (a roster
    /// sweep every few minutes, a token exchange per sign-in), so a couple of
    /// hundred covers well beyond any window the rule asks about.
    private static let capacity = 200

    struct Snapshot: Sendable {
        let failuresInWindow: Int
        let successesInWindow: Int
        let destinationsFailing: [String]
        let lastSuccessAt: Date?
    }

    private struct Attempt: Sendable {
        let at: Date
        let succeeded: Bool
        let destination: OutboundDestination
    }

    private var attempts: [Attempt] = []
    private var lastSuccessAt: Date?

    func record(
        success: Bool,
        destination: OutboundDestination,
        at now: Date = Date()
    ) {
        attempts.append(Attempt(at: now, succeeded: success, destination: destination))
        if attempts.count > Self.capacity {
            attempts.removeFirst(attempts.count - Self.capacity)
        }
        if success { lastSuccessAt = now }
    }

    func snapshot(window: TimeInterval, now: Date = Date()) -> Snapshot {
        let cutoff = now.addingTimeInterval(-window)
        let recent = attempts.filter { $0.at >= cutoff }
        let failing = Set(recent.filter { !$0.succeeded }.map { $0.destination.humanReadable })
        return Snapshot(
            failuresInWindow: recent.filter { !$0.succeeded }.count,
            successesInWindow: recent.filter { $0.succeeded }.count,
            destinationsFailing: failing.sorted(),
            lastSuccessAt: lastSuccessAt
        )
    }
}

// MARK: - Application storage

private struct OutboundReachabilityStoreKey: StorageKey {
    typealias Value = OutboundReachabilityStore
}

extension Application {
    /// Shared record of outbound reachability, read by the
    /// `outboundEgressFailing` health rule.
    var outboundReachability: OutboundReachabilityStore {
        lazyStored(OutboundReachabilityStoreKey.self) { OutboundReachabilityStore() }
    }
}

extension Application {
    /// Runs an outbound request and records whether the far end was REACHED.
    ///
    /// A non-2xx response still counts as reached: a 503 from the IdP means the
    /// network path works and the far end is unwell, which is a different
    /// problem and must not page as a severed egress. Only a thrown transport
    /// error — connect timeout, DNS failure, connection refused — records a
    /// failure.
    func recordingReachability<T>(
        _ destination: OutboundDestination,
        perform: sending () async throws -> T
    ) async throws -> T {
        do {
            let result = try await perform()
            await outboundReachability.record(success: true, destination: destination)
            return result
        } catch {
            await outboundReachability.record(success: false, destination: destination)
            throw error
        }
    }
}

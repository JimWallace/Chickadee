// APIServer/Services/MCPOAuthReaperService.swift
//
// Periodic cleanup of dead MCP OAuth rows:
//   • oauth_authorization_codes — single-use, 60-second-lived; one row per
//     /authorize. They're useless the moment they expire or are consumed, but
//     are never deleted in-flow, so they accumulate fast under any real use.
//   • oauth_consent_requests — single-use, ~10-minute-lived; one row per
//     rendered consent screen. Same accumulation problem.
//   • oauth_grants — refresh-token grants that are revoked or past their
//     expiry can never mint again, so they're safe to drop. (Reuse-detection
//     only consults non-revoked grants, so removing revoked ones is harmless.)
//
// Only runs when MCP is enabled. Periodic scaffolding lives in
// `PeriodicSweepMonitor`.

import Fluent
import Foundation
import Vapor

/// Hourly: dead OAuth rows are space hygiene, not correctness.
private let mcpOAuthReaperSweepInterval: TimeInterval = 3600

/// Deletes expired authorization codes, expired consent requests, and
/// revoked/expired grants.
func reapExpiredMCPOAuthRecords(on db: Database, logger: Logger, now: Date = Date()) async throws {
    // Auth codes are dead once expired OR consumed — a consumed code can never
    // be redeemed again (the atomic burn blocks it), so there's no reason to
    // keep it around until its 60-second TTL lapses.
    try await MCPAuthorizationCode.query(on: db)
        .group(.or) { group in
            group.filter(\.$expiresAt < now).filter(\.$consumed == true)
        }
        .delete()
    // Single-use consent requests: one row per rendered consent screen, dead
    // the moment they expire or are redeemed. Like auth codes, they accumulate.
    try await MCPConsentRequest.query(on: db)
        .group(.or) { group in
            group.filter(\.$expiresAt < now).filter(\.$consumed == true)
        }
        .delete()
    try await MCPGrant.query(on: db)
        .group(.or) { group in
            group.filter(\.$revoked == true).filter(\.$expiresAt < now)
        }
        .delete()
    logger.debug("MCP OAuth reaper sweep complete")
}

struct MCPOAuthReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var mcpOAuthReaperMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[MCPOAuthReaperMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "MCP OAuth reaper",
                interval: mcpOAuthReaperSweepInterval,
                runImmediately: true
            ) { application in
                try await reapExpiredMCPOAuthRecords(on: application.db, logger: application.logger)
            }
            storage[MCPOAuthReaperMonitorKey.self] = created
            return created
        }
        set { storage[MCPOAuthReaperMonitorKey.self] = newValue }
    }
}

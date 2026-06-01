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
// Only runs when MCP is enabled. Pattern mirrors `SessionReaperService` /
// `StuckSubmissionReaperService` for consistency.

import Fluent
import Foundation
import Vapor

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

final class MCPOAuthReaperMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64

    init(interval: TimeInterval = 3600) {
        intervalNanoseconds = UInt64(max(interval, 60) * 1_000_000_000)
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    try await reapExpiredMCPOAuthRecords(
                        on: application.db, logger: application.logger)
                } catch {
                    application.logger.error(
                        "MCP OAuth reaper sweep failed: \(error.localizedDescription)")
                }
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct MCPOAuthReaperMonitorKey: StorageKey {
    typealias Value = MCPOAuthReaperMonitor
}

struct MCPOAuthReaperLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            do {
                try await reapExpiredMCPOAuthRecords(
                    on: application.db, logger: application.logger)
            } catch {
                application.logger.error(
                    "Initial MCP OAuth reaper sweep failed: \(error.localizedDescription)")
            }
        }
        application.mcpOAuthReaperMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.mcpOAuthReaperMonitor.stop()
    }
}

extension Application {
    var mcpOAuthReaperMonitor: MCPOAuthReaperMonitor {
        get {
            if let existing = storage[MCPOAuthReaperMonitorKey.self] { return existing }
            let created = MCPOAuthReaperMonitor()
            storage[MCPOAuthReaperMonitorKey.self] = created
            return created
        }
        set { storage[MCPOAuthReaperMonitorKey.self] = newValue }
    }
}

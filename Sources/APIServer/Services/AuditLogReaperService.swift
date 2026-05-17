// APIServer/Services/AuditLogReaperService.swift
//
// Periodic cleanup of stale `audit_log` rows.  Rows accumulate forever
// without this — every authenticated action, login attempt, role change,
// retest, and admin operation lands one — and the table carries actor
// names, IPs, user-agents, and action metadata.  Under FIPPA / PIPEDA,
// indefinite retention of personally-identifying audit trails is not a
// defensible posture; periodic disposal once the operational need ends
// is the standard mitigation.
//
// Default retention: 90 days, overridable via `AUDIT_LOG_RETENTION_DAYS`.
// Setting it to 0 disables the reaper (kept around for installs that
// pipe audit_log to an external sink and want to manage retention there).
//
// Pattern mirrors `SessionReaperService` and `StuckSubmissionReaperService`
// for consistency.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Default audit-log retention.  90 days covers the usual "what happened
/// last term" debugging window without amassing years of identifying
/// metadata.
let auditLogDefaultMaxAge: TimeInterval = 90 * 24 * 60 * 60

/// Deletes audit_log rows older than `maxAge`.  A `maxAge` of zero (or
/// negative) is a no-op so operators can disable the reaper cleanly via
/// env var without removing the lifecycle handler.  `created_at` is
/// NOT NULL in the schema, so no null-guard is needed.
func reapStaleAuditLogEntries(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = auditLogDefaultMaxAge,
    now: Date = Date()
) async throws {
    guard maxAge > 0 else { return }
    guard let sql = db as? SQLDatabase else { return }
    let cutoff = now.addingTimeInterval(-maxAge)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let cutoffString = formatter.string(from: cutoff)

    try await sql.raw(
        "DELETE FROM audit_log WHERE created_at < \(bind: cutoffString)"
    ).run()
    logger.debug("Audit-log reaper sweep complete (cutoff=\(cutoffString))")
}

final class AuditLogReaperMonitor: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let maxAge: TimeInterval

    init(interval: TimeInterval = 3600, maxAge: TimeInterval = auditLogDefaultMaxAge) {
        intervalNanoseconds = UInt64(max(interval, 60) * 1_000_000_000)
        self.maxAge = maxAge
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task { [maxAge, intervalNanoseconds] in
            while !Task.isCancelled {
                do {
                    try await reapStaleAuditLogEntries(
                        on: application.db,
                        logger: application.logger,
                        maxAge: maxAge
                    )
                } catch {
                    application.logger.error(
                        "Audit-log reaper sweep failed: \(error.localizedDescription)"
                    )
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

struct AuditLogReaperMonitorKey: StorageKey {
    typealias Value = AuditLogReaperMonitor
}

struct AuditLogReaperLifecycleHandler: LifecycleHandler {
    let maxAge: TimeInterval

    init(maxAge: TimeInterval = auditLogDefaultMaxAge) {
        self.maxAge = maxAge
    }

    func didBoot(_ application: Application) throws {
        // Best-effort first sweep at boot so a restart after a long quiet
        // period doesn't have to wait an hour to reclaim space.
        let maxAgeCapture = maxAge
        Task {
            do {
                try await reapStaleAuditLogEntries(
                    on: application.db,
                    logger: application.logger,
                    maxAge: maxAgeCapture
                )
            } catch {
                application.logger.error(
                    "Initial audit-log reaper sweep failed: \(error.localizedDescription)"
                )
            }
        }
        application.auditLogReaperMonitor(maxAge: maxAge).start(application: application)
    }

    func shutdown(_ application: Application) {
        application.storage[AuditLogReaperMonitorKey.self]?.stop()
    }
}

extension Application {
    /// Returns the singleton monitor, creating it with the supplied
    /// `maxAge` on first access.  Subsequent calls ignore the parameter —
    /// the caller (lifecycle handler) is the one source of truth for
    /// retention configuration.
    func auditLogReaperMonitor(maxAge: TimeInterval = auditLogDefaultMaxAge) -> AuditLogReaperMonitor {
        if let existing = storage[AuditLogReaperMonitorKey.self] { return existing }
        let created = AuditLogReaperMonitor(maxAge: maxAge)
        storage[AuditLogReaperMonitorKey.self] = created
        return created
    }
}

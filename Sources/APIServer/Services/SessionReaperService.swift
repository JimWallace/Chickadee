// APIServer/Services/SessionReaperService.swift
//
// Periodic cleanup of expired session rows from Vapor's `_fluent_sessions`
// table.  Without this, every request that doesn't carry a recognised
// session cookie can create a new row, and rows are never deleted
// server-side — only the cookie expires.  Over months that table grows
// without bound; in front of an active vulnerability scanner it can grow
// fast.
//
// The `created_at` column (added by `AddSessionsCreatedAt`) is populated
// via a column DEFAULT, so the model class is unchanged.  Rows older than
// `maxAge` are deleted; rows with NULL `created_at` (pre-migration) are
// preserved on the assumption they'll be rewritten by Vapor on the next
// session save and pick up a real timestamp.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the sweep itself plus its storage key and accessor.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Sessions older than this default are considered stale and reaped.  8 days
/// = the 7-day cookie lifetime + 1-day grace for clock skew and stale-but-
/// still-valid cookies that a slow client might be holding.
private let sessionDefaultMaxAge: TimeInterval = 8 * 24 * 60 * 60

/// Hourly: stale-session reclamation is space hygiene, not correctness.
private let sessionReaperSweepInterval: TimeInterval = 3600

func reapStaleSessions(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = sessionDefaultMaxAge,
    now: Date = Date()
) async throws {
    guard let sql = db as? SQLDatabase else { return }
    let cutoff = now.addingTimeInterval(-maxAge)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let cutoffString = formatter.string(from: cutoff)

    // Pre-migration rows have NULL created_at; preserve them — they'll roll
    // out as Vapor rewrites the row on the next session save.
    try await sql.raw(
        "DELETE FROM _fluent_sessions WHERE created_at IS NOT NULL AND created_at < \(bind: cutoffString)"
    ).run()
    logger.debug("Session reaper sweep complete (cutoff=\(cutoffString))")
}

struct SessionReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var sessionReaperMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[SessionReaperMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Session reaper",
                interval: sessionReaperSweepInterval,
                runImmediately: true
            ) { application in
                try await reapStaleSessions(on: application.db, logger: application.logger)
            }
            storage[SessionReaperMonitorKey.self] = created
            return created
        }
        set { storage[SessionReaperMonitorKey.self] = newValue }
    }
}

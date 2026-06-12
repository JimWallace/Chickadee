// APIServer/Services/ActivityEventReaperService.swift
//
// Periodic cleanup of stale `user_activity_events` rows.  These rows back the
// admin dashboard's "active users over time" chart, whose longest window is
// one month; anything older is never charted and only grows the table.  A
// 35-day retention covers the month window plus a few days of slack.
//
// Uses Fluent's typed query (not raw SQL) so the `Date < timestamptz`
// comparison works identically on SQLite and Postgres — same reasoning as
// AuditLogReaperService.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the sweep itself plus its storage key and accessor.

import Fluent
import Foundation
import Vapor

/// Default activity-event retention: 35 days (the 30-day chart window plus
/// slack for clock skew and so a just-past-window day still renders fully).
let activityEventDefaultMaxAge: TimeInterval = 35 * 24 * 60 * 60

/// Hourly: stale-event reclamation is space hygiene, not correctness.
private let activityEventReaperSweepInterval: TimeInterval = 3600

/// Deletes `user_activity_events` rows older than `maxAge`.  `created_at` is
/// NOT NULL in the schema, so no null-guard is needed.
func reapStaleActivityEvents(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = activityEventDefaultMaxAge,
    now: Date = Date()
) async throws {
    guard maxAge > 0 else { return }
    let cutoff = now.addingTimeInterval(-maxAge)
    try await APIUserActivityEvent.query(on: db)
        .filter(\.$createdAt < cutoff)
        .delete()
    logger.debug("Activity-event reaper sweep complete (cutoff=\(cutoff))")
}

struct ActivityEventReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var activityEventReaperMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[ActivityEventReaperMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Activity-event reaper",
                interval: activityEventReaperSweepInterval,
                runImmediately: true
            ) { application in
                try await reapStaleActivityEvents(on: application.db, logger: application.logger)
            }
            storage[ActivityEventReaperMonitorKey.self] = created
            return created
        }
        set { storage[ActivityEventReaperMonitorKey.self] = newValue }
    }
}

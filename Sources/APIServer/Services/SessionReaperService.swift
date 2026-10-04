// APIServer/Services/SessionReaperService.swift
//
// Periodic cleanup of expired session rows from Vapor's `_fluent_sessions`
// table.  Without this, every request that doesn't carry a recognised
// session cookie can create a new row, and rows are never deleted
// server-side — only the cookie expires.  Over months that table grows
// without bound; in front of an active vulnerability scanner it can grow
// fast, which then slows the per-request session lookup on every
// authenticated page load.
//
// The `created_at` column (added by `AddSessionsCreatedAt`) is populated
// via a column DEFAULT, so Vapor's `SessionRecord` model is unchanged.  Rows
// older than `maxAge` are deleted; rows with NULL `created_at` (pre-migration)
// are preserved — `created_at < cutoff` is never true for NULL, so they fall
// out naturally once Vapor rewrites the row on the next session save and it
// picks up a real timestamp.
//
// This uses a Fluent typed query — the SAME pattern as `AuditLogReaperService`
// and `UserActivityEventReaperService` — rather than hand-rolled raw SQL, so the
// `Date < created_at` comparison binds correctly on BOTH SQLite and Postgres.
// The previous raw-SQL form compared the `timestamp` column to a text-bound
// ISO8601 cutoff (`created_at < <string>`); SQLite's loose typing accepted it,
// but Postgres rejected `timestamp < text` and the sweep threw every hour, so
// sessions never got reaped.  Keeping all three reapers on the one Fluent
// pattern is the fix for that divergence.
//
// SQLite is the one exception, and it is the opposite problem (#1810). SQLite
// stores the column DEFAULT, `CURRENT_TIMESTAMP`, as TEXT, while a bound `Date`
// is a REAL, and SQLite orders every REAL below every TEXT. So the typed filter
// never matched a row Vapor wrote, and a dev database's sessions were never
// reaped. On SQLite the sweep compares both encodings as seconds since 1970.
// Postgres keeps the typed query.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the sweep itself, the minimal model it queries, and the storage key/accessor.

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

/// Deletes `_fluent_sessions` rows older than `maxAge`.  Rows with NULL
/// `created_at` are preserved (the comparison is never true for NULL).
func reapStaleSessions(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = sessionDefaultMaxAge,
    now: Date = Date()
) async throws {
    let cutoff = now.addingTimeInterval(-maxAge)
    if let sql = db as? SQLDatabase, sql.dialect.name == "sqlite" {
        // A TEXT value is the column default; anything else is a bound Date
        // (REAL seconds). A NULL matches neither branch's comparison.
        try await sql.raw(
            """
            DELETE FROM _fluent_sessions WHERE
                (CASE typeof(created_at)
                    WHEN 'text' THEN (julianday(created_at) - 2440587.5) * 86400.0
                    ELSE created_at
                END) < \(bind: cutoff.timeIntervalSince1970)
            """
        ).run()
    } else {
        try await ReapableSession.query(on: db)
            .filter(\.$createdAt < cutoff)
            .delete()
    }
    logger.debug("Session reaper sweep complete (cutoff=\(cutoff))")
}

struct SessionReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var sessionReaperMonitor: PeriodicSweepMonitor {
        lazyStored(SessionReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "Session reaper",
                interval: sessionReaperSweepInterval
            ) { application in
                try await reapStaleSessions(on: application.db, logger: application.logger)
            }
        }
    }
}

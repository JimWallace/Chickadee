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
// and `ActivityEventReaperService` — rather than hand-rolled raw SQL, so the
// `Date < created_at` comparison binds correctly on BOTH SQLite and Postgres.
// The previous raw-SQL form compared the `timestamp` column to a text-bound
// ISO8601 cutoff (`created_at < <string>`); SQLite's loose typing accepted it,
// but Postgres rejected `timestamp < text` and the sweep threw every hour, so
// sessions never got reaped.  Keeping all three reapers on the one Fluent
// pattern is the fix for that divergence.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the sweep itself, the minimal model it queries, and the storage key/accessor.

import Fluent
import Foundation
import Vapor

/// Sessions older than this default are considered stale and reaped.  8 days
/// = the 7-day cookie lifetime + 1-day grace for clock skew and stale-but-
/// still-valid cookies that a slow client might be holding.
private let sessionDefaultMaxAge: TimeInterval = 8 * 24 * 60 * 60

/// Hourly: stale-session reclamation is space hygiene, not correctness.
private let sessionReaperSweepInterval: TimeInterval = 3600

/// Minimal Fluent view of Vapor's `_fluent_sessions` table, used only by the
/// reaper so it can age rows out with the same typed `created_at < cutoff`
/// query the other reapers use.  It deliberately maps only `id` and the
/// `created_at` column added by `AddSessionsCreatedAt`; the `key`/`data`
/// columns are owned and written by Fluent's `SessionRecord`.  No migration is
/// attached — the table already exists.
///
/// `@unchecked Sendable` for the same reason as every Fluent model here:
/// `Model` requires reference semantics with mutable stored properties, and
/// Fluent's own `SessionRecord` is declared the same way.
final class ReapableSession: Model, @unchecked Sendable {
    static let schema = "_fluent_sessions"

    @ID(key: .id) var id: UUID?

    /// Nullable: pre-`AddSessionsCreatedAt` rows have NULL here and are left
    /// untouched by the reaper (NULL never satisfies `< cutoff`).
    @OptionalField(key: "created_at") var createdAt: Date?

    init() {}
}

/// Deletes `_fluent_sessions` rows older than `maxAge`.  Rows with NULL
/// `created_at` are preserved (the comparison is never true for NULL).
func reapStaleSessions(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = sessionDefaultMaxAge,
    now: Date = Date()
) async throws {
    let cutoff = now.addingTimeInterval(-maxAge)
    try await ReapableSession.query(on: db)
        .filter(\.$createdAt < cutoff)
        .delete()
    logger.debug("Session reaper sweep complete (cutoff=\(cutoff))")
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

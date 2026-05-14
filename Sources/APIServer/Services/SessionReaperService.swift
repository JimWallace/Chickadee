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
// Pattern mirrors `StuckSubmissionReaperService` for consistency.

import Fluent
import Foundation
import SQLKit
import Vapor

/// Sessions older than this default are considered stale and reaped.  8 days
/// = the 7-day cookie lifetime + 1-day grace for clock skew and stale-but-
/// still-valid cookies that a slow client might be holding.
private let sessionDefaultMaxAge: TimeInterval = 8 * 24 * 60 * 60

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

final class SessionReaperMonitor: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let maxAge: TimeInterval

    init(interval: TimeInterval = 3600, maxAge: TimeInterval = sessionDefaultMaxAge) {
        intervalNanoseconds = UInt64(max(interval, 60) * 1_000_000_000)
        self.maxAge = maxAge
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    try await reapStaleSessions(
                        on: application.db,
                        logger: application.logger,
                        maxAge: maxAge
                    )
                } catch {
                    application.logger.error(
                        "Session reaper sweep failed: \(error.localizedDescription)"
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

struct SessionReaperMonitorKey: StorageKey {
    typealias Value = SessionReaperMonitor
}

struct SessionReaperLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        // Best-effort first sweep at boot so a restart after a long quiet
        // period doesn't have to wait an hour to reclaim space.
        Task {
            do {
                try await reapStaleSessions(
                    on: application.db,
                    logger: application.logger
                )
            } catch {
                application.logger.error(
                    "Initial session reaper sweep failed: \(error.localizedDescription)"
                )
            }
        }
        application.sessionReaperMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.sessionReaperMonitor.stop()
    }
}

extension Application {
    var sessionReaperMonitor: SessionReaperMonitor {
        get {
            if let existing = storage[SessionReaperMonitorKey.self] { return existing }
            let created = SessionReaperMonitor()
            storage[SessionReaperMonitorKey.self] = created
            return created
        }
        set { storage[SessionReaperMonitorKey.self] = newValue }
    }
}

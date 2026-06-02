// APIServer/Services/ActivityEventReaperService.swift
//
// Periodic cleanup of stale `user_activity_events` rows.  These rows back the
// admin dashboard's "active users over time" chart, whose longest window is
// one month; anything older is never charted and only grows the table.  A
// 35-day retention covers the month window plus a few days of slack.
//
// Uses Fluent's typed query (not raw SQL) so the `Date < timestamptz`
// comparison works identically on SQLite and Postgres — same reasoning as
// AuditLogReaperService.  Pattern mirrors SessionReaperService /
// AuditLogReaperService for consistency.

import Fluent
import Foundation
import Vapor

/// Default activity-event retention: 35 days (the 30-day chart window plus
/// slack for clock skew and so a just-past-window day still renders fully).
let activityEventDefaultMaxAge: TimeInterval = 35 * 24 * 60 * 60

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

final class ActivityEventReaperMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let maxAge: TimeInterval

    init(interval: TimeInterval = 3600, maxAge: TimeInterval = activityEventDefaultMaxAge) {
        intervalNanoseconds = UInt64(max(interval, 60) * 1_000_000_000)
        self.maxAge = maxAge
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    try await reapStaleActivityEvents(
                        on: application.db,
                        logger: application.logger,
                        maxAge: maxAge
                    )
                } catch {
                    application.logger.error(
                        "Activity-event reaper sweep failed: \(error.localizedDescription)"
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

struct ActivityEventReaperMonitorKey: StorageKey {
    typealias Value = ActivityEventReaperMonitor
}

struct ActivityEventReaperLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        // Best-effort first sweep at boot so a restart after a long quiet
        // period doesn't have to wait an hour to reclaim space.
        Task {
            do {
                try await reapStaleActivityEvents(
                    on: application.db,
                    logger: application.logger
                )
            } catch {
                application.logger.error(
                    "Initial activity-event reaper sweep failed: \(error.localizedDescription)"
                )
            }
        }
        application.activityEventReaperMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.activityEventReaperMonitor.stop()
    }
}

extension Application {
    var activityEventReaperMonitor: ActivityEventReaperMonitor {
        get {
            if let existing = storage[ActivityEventReaperMonitorKey.self] { return existing }
            let created = ActivityEventReaperMonitor()
            storage[ActivityEventReaperMonitorKey.self] = created
            return created
        }
        set { storage[ActivityEventReaperMonitorKey.self] = newValue }
    }
}

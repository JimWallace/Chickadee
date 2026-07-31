// APIServer/Services/DataExportRecoveryService.swift
//
// Liveness backstop for the personal-data export pipeline (#557).
//
// Export generation runs in a detached background task inside the server
// process (`DataExportManager` → `generateDataExport`).  That task cannot
// survive the process: a blue-green redeploy, crash, or OOM while an export
// is still generating leaves its `data_exports` row stuck `pending` forever.
// Nothing in the next process owns that orphaned row, and the account page's
// status poll (`account-export.js`) only stops when the row leaves `pending`
// — so the user watches "your export is being prepared … this page will
// refresh when it is ready" indefinitely and is never told their data is
// ready or that it failed.
//
// `generateDataExport` already funnels every in-process error to a terminal
// `failed` state, so the ONLY way a row lingers in `pending` is an
// interrupted generation.  This sweep is the recovery for exactly that: it
// flips such orphaned rows to `failed`, which lets the poll resolve, surfaces
// the "last export attempt failed — please try again" notice, and re-exposes
// the request button (`dataExportCanBeRequested` already treats a `failed`
// row as re-requestable).  Retention of the generated zips is a separate
// concern in `DataExportRetentionService.swift`.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor` (leader-leased, so
// multi-process deployments sweep once per tick) — same pattern as the
// stuck-submission reaper this mirrors.

import Fluent
import Foundation
import Vapor

/// Sweep every minute so an interrupted export is unstuck promptly once it
/// crosses the staleness threshold, rather than lingering until the hourly
/// retention pass.
private let staleDataExportSweepInterval: TimeInterval = 60

/// Flips `pending` export rows older than `maxAge` to `failed`.
///
/// `maxAge` defaults to `dataExportStalePendingAge` — the same threshold at
/// which `dataExportCanBeRequested` re-opens the request button — so a stuck
/// row becomes "failed, try again" and re-requestable at the same instant,
/// keeping the state machine coherent.
///
/// The flip is a single conditional `UPDATE … WHERE status = 'pending'`, so it
/// cannot clobber a very slow but genuine generation that completes between
/// the read and the write: the database re-checks `status` at execution time,
/// and a row that has since reached `complete` is excluded.  Returns the
/// number of rows failed (for tests / logging).
@discardableResult
func failStalePendingDataExports(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = dataExportStalePendingAge,
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-maxAge)

    func scoped() -> QueryBuilder<APIDataExport> {
        APIDataExport.query(on: db)
            .filter(\.$status == DataExportStatus.pending.rawValue)
            .filter(\.$requestedAt <= cutoff)
    }

    // Read the orphaned (id, user) pairs first so each failure can be logged
    // by owner, then flip the whole set in one conditional UPDATE.  A row that
    // ages past the cutoff between the read and the UPDATE is caught by the
    // next sweep; a row that completes in that window is excluded by the
    // UPDATE's `status = 'pending'` predicate — benign either way.
    let stale = try await scoped().field(\.$id).field(\.$userID).all()
    guard !stale.isEmpty else { return 0 }

    let minutes = Int((maxAge / 60).rounded())
    try await scoped()
        .set(\.$status, to: DataExportStatus.failed.rawValue)
        .set(\.$completedAt, to: now)
        .set(
            \.$failureReason,
            to: "Generation did not complete within \(minutes) minutes "
                + "(interrupted — most likely a server restart during generation)."
        )
        .update()

    for export in stale {
        // User id in metadata only — message text reaches the admin
        // query_logs buffer unredacted (compliance audit F-1).
        logger.warning(
            "data_export reaper: failed stale pending export \(export.id?.uuidString ?? "<nil>"); user can now request a fresh export",
            metadata: ["user_id": .string(export.userID.uuidString)]
        )
    }
    return stale.count
}

struct StaleDataExportReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var staleDataExportReaperMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[StaleDataExportReaperMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Stale data-export reaper",
                interval: staleDataExportSweepInterval,
                minimumInterval: 1,
                runImmediately: true
            ) { application in
                _ = try await failStalePendingDataExports(
                    on: application.db,
                    logger: application.logger
                )
            }
            storage[StaleDataExportReaperMonitorKey.self] = created
            return created
        }
        set {
            storage[StaleDataExportReaperMonitorKey.self] = newValue
        }
    }
}

// APIServer/Services/DataExportRetentionService.swift
//
// Periodic cleanup of generated personal-data exports (#557).  Each export
// zip is a bundle of one user's personal information sitting on disk;
// leaving it there indefinitely defeats the point of careful retention
// elsewhere (audit-log reaper, submission retention).  Exports are kept
// long enough for the requester to download at leisure, then the zip and
// its tracking row are deleted — the user can always request a fresh one.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor` (leader-leased, so
// multi-process deployments sweep once per tick).

import Fluent
import Foundation
import Vapor

/// How long a generated export remains downloadable.  Three days comfortably
/// covers "requested Friday, downloaded Monday" while keeping bundled
/// personal data short-lived; it also exceeds the one-per-day request
/// interval, so an expired row never extends the rate limit.
let dataExportRetentionMaxAge: TimeInterval = 72 * 60 * 60

/// Hourly: export disposal is retention hygiene, not correctness.
private let dataExportReaperSweepInterval: TimeInterval = 3600

/// Deletes export rows requested more than `maxAge` ago, removing each
/// row's generated zip first.  Terminal-state agnostic: an expired pending
/// or failed row is just as dead as a complete one.
func reapExpiredDataExports(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = dataExportRetentionMaxAge,
    now: Date = Date()
) async throws {
    guard maxAge > 0 else { return }
    let cutoff = now.addingTimeInterval(-maxAge)
    let expired = try await APIDataExport.query(on: db)
        .filter(\.$requestedAt < cutoff)
        .all()
    guard !expired.isEmpty else { return }

    var removed = 0
    for export in expired {
        if let zipPath = export.zipPath, FileManager.default.fileExists(atPath: zipPath) {
            do {
                try FileManager.default.removeItem(atPath: zipPath)
            } catch {
                // Keep the row so the next sweep retries the file delete —
                // dropping the row first would orphan the zip forever.
                logger.warning(
                    "Data-export reaper could not delete \(zipPath): \(error.localizedDescription)"
                )
                continue
            }
        }
        try await export.delete(on: db)
        removed += 1
    }
    logger.info("Data-export reaper removed \(removed) expired export(s)")
}

struct DataExportReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var dataExportReaperMonitor: PeriodicSweepMonitor {
        if let existing = storage[DataExportReaperMonitorKey.self] { return existing }
        let created = PeriodicSweepMonitor(
            name: "Data-export reaper",
            interval: dataExportReaperSweepInterval,
            runImmediately: true
        ) { application in
            try await reapExpiredDataExports(
                on: application.db,
                logger: application.logger
            )
        }
        storage[DataExportReaperMonitorKey.self] = created
        return created
    }
}

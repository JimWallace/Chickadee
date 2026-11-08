// APIServer/Services/ClientDiagnosticsReaperService.swift
//
// Deletes `client_diagnostics` rows older than the retention window on a
// leased periodic sweep (#2900). Nothing removed them before, so a student
// could grow the table without bound and every row was kept forever.
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the window, the interval, the purge and the accessor.

import Fluent
import Vapor

/// How long a browser diagnostic row is kept: 90 days, the maintainer's
/// decision of 2026-11-08 (#2900). A fixed value, not a setting: the house
/// rule adds no environment variable.
let clientDiagnosticsRetention: TimeInterval = 90 * 86_400

/// The window is days long, so an hourly sweep keeps the table close to it.
private let clientDiagnosticsReaperSweepInterval: TimeInterval = 3600

enum ClientDiagnosticsReaper {
    /// Deletes the rows created before `now - clientDiagnosticsRetention`.
    /// Best-effort: a failed purge only delays cleanup.
    static func purgeExpired(db: any Database, logger: Logger, now: Date = Date()) async {
        let cutoff = now.addingTimeInterval(-clientDiagnosticsRetention)
        do {
            try await APIClientDiagnostic.query(on: db)
                .filter(\.$createdAt < cutoff)
                .delete()
        } catch {
            logger.warning("client_diagnostics_purge_failed: \(String(describing: error))")
        }
    }
}

struct ClientDiagnosticsReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var clientDiagnosticsReaperMonitor: PeriodicSweepMonitor {
        lazyStored(ClientDiagnosticsReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "Client-diagnostics reaper",
                interval: clientDiagnosticsReaperSweepInterval
            ) { application in
                await ClientDiagnosticsReaper.purgeExpired(db: application.db, logger: application.logger)
            }
        }
    }
}

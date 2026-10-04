// APIServer/Services/DiagnosticsPruneService.swift
//
// Applies the diagnostics retention windows on a leased periodic sweep: job
// metrics, runner snapshots, request metrics and submission diagnostics. It
// used to run inside a student's submission, a runner's poll and a runner's
// result report, behind a per-process throttle with no lease, plus once from
// a boot task (#1924).
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the storage key and the accessor.

import Vapor

struct DiagnosticsPruneMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    /// Runs at `pruneIntervalHours`. An interval of 0 or less turns pruning
    /// off, as it always has; the monitor still ticks hourly and does nothing.
    var diagnosticsPruneMonitor: PeriodicSweepMonitor {
        lazyStored(DiagnosticsPruneMonitorKey.self) {
            let hours = diagnostics.configuration.pruneIntervalHours
            return PeriodicSweepMonitor(
                name: "Diagnostics prune",
                interval: TimeInterval(max(hours, 1)) * 3600
            ) { application in
                guard application.diagnostics.configuration.pruneIntervalHours > 0 else { return }
                await application.diagnostics.pruneNow(on: application.db, logger: application.logger)
            }
        }
    }
}

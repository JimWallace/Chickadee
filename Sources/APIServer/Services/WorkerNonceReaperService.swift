// APIServer/Services/WorkerNonceReaperService.swift
//
// Deletes expired `worker_nonces` rows on a leased periodic sweep. The
// HMAC middleware used to do it inside a runner's request, behind a
// per-process throttle with no lease, so every server instance pruned
// (#1924).
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the interval, the storage key and the accessor.

import Vapor

/// A nonce lives for `nonceTTLSeconds` (minutes), so a one-minute sweep keeps
/// the table near the rows that are still live.
private let workerNonceReaperSweepInterval: TimeInterval = 60

struct WorkerNonceReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var workerNonceReaperMonitor: PeriodicSweepMonitor {
        lazyStored(WorkerNonceReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "Worker-nonce reaper",
                interval: workerNonceReaperSweepInterval,
                runImmediately: true
            ) { application in
                await WorkerNonceReplayGuard.purgeExpired(db: application.db, logger: application.logger)
            }
        }
    }
}

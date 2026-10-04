// APIServer/Services/LoginAttemptReaperService.swift
//
// Deletes `login_attempts` rows that are outside every window, on a leased
// periodic sweep. The rate-limit middleware used to do it inside a login
// request, behind a per-process throttle with no lease, so every server
// instance pruned (#1924).
//
// Periodic scaffolding lives in `PeriodicSweepMonitor`; this file keeps only
// the interval, the storage key and the accessor.

import Vapor

/// Every ten minutes: the rows are bounded per key on write, so this only
/// collects keys that never came back.
private let loginAttemptReaperSweepInterval: TimeInterval = 600

struct LoginAttemptReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var loginAttemptReaperMonitor: PeriodicSweepMonitor {
        lazyStored(LoginAttemptReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "Login-attempt reaper",
                interval: loginAttemptReaperSweepInterval
            ) { application in
                await LoginAttemptService.purgeStale(
                    db: application.db,
                    lockoutWindowSeconds: application.loginRateLimitConfiguration.lockoutWindowSeconds,
                    logger: application.logger)
            }
        }
    }
}

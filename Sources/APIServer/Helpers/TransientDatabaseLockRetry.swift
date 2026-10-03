// APIServer/Helpers/TransientDatabaseLockRetry.swift
//
// The one retry for a transient SQLite lock (#1926), beside
// `withWriteLockedTransaction`, which removes most of the locks it retries.
//
// There were two: `retrySQLiteBusyClaim` (worker claims: three attempts, a
// fixed 20 ms) and `withTransientDatabaseLockRetry` (attempt numbers and
// result effects: six attempts, doubling from 10 ms). They decided "is this a
// lock?" with two different classifiers, so a lock one of them retried could
// fail at once in the other. Both callers keep their own attempt count and
// backoff; the classifier is now one function that accepts everything either
// of the old ones did.

import Fluent
import FluentSQLiteDriver
import Foundation

/// How long `withTransientDatabaseLockRetry` waits after a failed attempt.
enum LockRetryBackoff: Sendable, Equatable {
    /// The same wait after every attempt.
    case fixed(Duration)
    /// `initial` after the first attempt, then twice the previous wait.
    case doubling(from: Duration)

    /// The wait after failed attempt `attempt` (1-based).
    func wait(afterAttempt attempt: Int) -> Duration {
        switch self {
        case .fixed(let wait): return wait
        case .doubling(let initial): return initial * (1 << (attempt - 1))
        }
    }
}

/// Runs `operation`, and runs it again when it fails with a transient SQLite
/// lock, up to `maxAttempts` times in total. Waits as `backoff` says after
/// each failed attempt. Any other error is thrown at once, and
/// so is the lock error from the last attempt. A cancelled task stops waiting
/// and throws `CancellationError`.
///
/// SQLite (even in WAL mode) allows only one writer at a time. An ordinary
/// contended write waits: sqlite-nio installs a busy handler that retries for
/// as long as it takes. What fails at once is a deferred read-then-write
/// transaction, which cannot wait for the write lock once it has read: it
/// fails when another connection holds the lock (`SQLITE_BUSY`) or has
/// committed since the read (`SQLITE_BUSY_SNAPSHOT`).
/// `withWriteLockedTransaction` removes both cases for the attempt-number
/// transaction (#1919), so there this retry is a backstop. Without it, the
/// contention surfaced as an intermittent HTTP 500 (notably on
/// `POST /submissions/browser-result`).
///
/// `operation` must be safe to re-run: a failed transaction rolls back (no row
/// committed, a model's create not marked as existing), so a whole transaction
/// is. Postgres serializes with advisory locks or row locks instead, so there
/// the retry never fires.
func withTransientDatabaseLockRetry<T>(
    on db: any Database,
    maxAttempts: Int = 6,
    backoff: LockRetryBackoff = .doubling(from: .milliseconds(10)),
    operation: () async throws -> T
) async throws -> T {
    precondition(maxAttempts > 0, "maxAttempts must be positive")
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            guard attempt < maxAttempts, isTransientDatabaseLockError(error) else { throw error }
            db.logger.warning(
                "Transient DB lock on attempt \(attempt)/\(maxAttempts): \(error) — retrying")
            try await Task.sleep(for: backoff.wait(afterAttempt: attempt))
        }
    }
}

/// Whether `error` is a transient SQLite lock: `SQLITE_BUSY` (in any of its
/// forms) or `SQLITE_LOCKED`.
///
/// The typed reason is asked first. The text is asked too, because a driver
/// or pool can wrap the error, and then only its description survives.
func isTransientDatabaseLockError(_ error: any Error) -> Bool {
    if let sqliteError = error as? SQLiteError {
        switch sqliteError.reason {
        case .busy, .busyInRecovery, .busyInSnapshot, .busyTimeout, .locked:
            return true
        default:
            break
        }
    }
    let text = (String(describing: error) + " " + error.localizedDescription).lowercased()
    return text.contains("database is locked")
        || text.contains("database table is locked")
        || text.contains("sqlite_busy")
        || text.contains("sqlite_locked")
        || text.contains("is busy")
}

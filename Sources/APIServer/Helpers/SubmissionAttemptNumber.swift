// APIServer/Helpers/SubmissionAttemptNumber.swift
//
// Race-free attempt-number assignment (June 2026 audit, P0.3). The previous
// count-then-insert pattern let two concurrent submits observe the same prior
// count and share an attempt number, silently corrupting the prior-attempt
// delta and the First-Try-Perfect badge.

import Fluent
import Foundation
import SQLKit

/// Saves `submission` with the next attempt number for its (test setup, user)
/// scope, computed and persisted inside one transaction.
///
/// On Postgres the transaction additionally takes a per-scope advisory lock
/// (`pg_advisory_xact_lock`, auto-released at commit) so two truly concurrent
/// transactions serialize instead of both reading the same `MAX`. On SQLite
/// the transaction takes the write lock before it reads
/// (`withWriteLockedTransaction`), so it waits for a competing writer instead
/// of failing when it writes after the `MAX` read (#1919).
///
/// `MAX(attempt_number) + 1` is used rather than `COUNT + 1` so deleted rows
/// can never cause a reused attempt number.
func saveSubmissionWithNextAttemptNumber(
    _ submission: APISubmission,
    userID: UUID?,
    on db: Database
) async throws {
    try await withTransientDatabaseLockRetry(on: db) {
        try await withWriteLockedTransaction(on: db) { tx in
            if let sql = tx as? SQLDatabase, sql.dialect.name == "postgresql" {
                let scope = "chickadee.attempt:\(submission.testSetupID):\(userID?.uuidString ?? "-")"
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: scope)))").run()
            }

            let query = APISubmission.query(on: tx)
                .filter(\.$testSetupID == submission.testSetupID)
                .filter(\.$kind == APISubmission.Kind.student)
            if let userID {
                _ = query.filter(\.$userID == userID)
            }
            // max() on an optional field yields Int?? — flatten both levels.
            let maxAttempt = (try await query.max(\.$attemptNumber)).flatMap { $0 } ?? 0

            submission.attemptNumber = maxAttempt + 1
            try await submission.save(on: tx)
        }
    }
}

/// Retries a database write on a transient SQLite lock error (`SQLITE_BUSY` /
/// "database is locked").
///
/// SQLite (even in WAL mode) allows only one writer at a time. An ordinary
/// contended write waits: sqlite-nio installs a busy handler that retries for as
/// long as it takes. What fails at once is a deferred read-then-write
/// transaction, which cannot wait for the write lock once it has read: it fails
/// when another connection holds the lock (`SQLITE_BUSY`) or has committed since
/// the read (`SQLITE_BUSY_SNAPSHOT`). `withWriteLockedTransaction` removes both
/// cases for the attempt-number transaction above (#1919), so this retry is now
/// a backstop, and the only correct recovery for anything else that reaches it
/// is to re-run the whole transaction against a fresh snapshot.
/// Without it, the contention surfaced to callers as an intermittent HTTP 500
/// (notably on `POST /submissions/browser-result`).
///
/// The transaction body is idempotent under retry: a failed transaction rolls
/// back (no row committed, the model's create is not marked as existing), so a
/// re-run recomputes the attempt number from a fresh `MAX` and inserts cleanly.
/// Postgres serializes via the advisory lock instead and won't hit this; the
/// retry is a harmless no-op there.
func withTransientDatabaseLockRetry<T>(
    on db: Database,
    maxAttempts: Int = 6,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            guard attempt < maxAttempts, isTransientDatabaseLockError(error) else { throw error }
            db.logger.warning(
                "Transient DB lock on attempt \(attempt)/\(maxAttempts): \(error) — retrying")
            // Escalating backoff: 10, 20, 40, 80, 160 ms.
            try? await Task.sleep(nanoseconds: UInt64(10_000_000) << UInt64(attempt - 1))
        }
    }
}

/// Whether `error` looks like a transient SQLite lock (`SQLITE_BUSY` /
/// `SQLITE_LOCKED` / "database is locked"). Matched on the error text so this
/// helper needs no SQLiteNIO import and tolerates how the driver wraps the code.
private func isTransientDatabaseLockError(_ error: Error) -> Bool {
    let text = String(describing: error).lowercased()
    return text.contains("database is locked")
        || text.contains("database table is locked")
        || text.contains("sqlite_busy")
        || text.contains("sqlite_locked")
        || text.contains("is busy")
}

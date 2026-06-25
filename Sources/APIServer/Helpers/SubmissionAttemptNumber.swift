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
/// transactions serialize instead of both reading the same `MAX`. On SQLite a
/// write transaction already serializes writers, so the lock is unnecessary.
///
/// `MAX(attempt_number) + 1` is used rather than `COUNT + 1` so deleted rows
/// can never cause a reused attempt number.
func saveSubmissionWithNextAttemptNumber(
    _ submission: APISubmission,
    userID: UUID?,
    on db: Database
) async throws {
    try await withTransientDatabaseLockRetry(on: db) {
        try await db.transaction { tx in
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
/// SQLite (even in WAL mode) allows only one writer at a time, and the app does
/// not set a `busy_timeout`, so a contended write fails *immediately* rather than
/// waiting. Worse, a deferred read-then-write transaction (e.g. the
/// `MAX(attempt_number)` read above followed by the insert) can get
/// `SQLITE_BUSY_SNAPSHOT` when another connection — a Fluent-backed session
/// write, a background monitor — commits between this transaction's read and its
/// write; that is a *stale snapshot* a `busy_timeout` could not absorb (waiting
/// doesn't refresh the snapshot), so the only correct recovery is to re-run the
/// whole transaction against a fresh snapshot. Without this, the contention
/// surfaced to callers as an intermittent HTTP 500 (notably on
/// `POST /submissions/browser-result`).
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

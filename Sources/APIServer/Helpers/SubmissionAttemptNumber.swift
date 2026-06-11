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
        let maxAttempt = (try await query.max(\.$attemptNumber) ?? nil) ?? 0

        submission.attemptNumber = maxAttempt + 1
        try await submission.save(on: tx)
    }
}

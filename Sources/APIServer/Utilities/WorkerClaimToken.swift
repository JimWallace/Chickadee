// APIServer/Utilities/WorkerClaimToken.swift
//
// The token that names one claim of a submission.

import Foundation

/// Names one claim of a submission by the claim's `assigned_at`, to the
/// microsecond the database stores. The job payload carries it
/// (`Job.claimToken`), the runner echoes it in its report, and result ingest
/// compares it with the row's current `assigned_at`
/// (`ResultClaimCheck`). Every claim writes a fresh `assigned_at`, and a
/// re-queue clears it, so a report for an earlier claim of the row, even by
/// the same runner, no longer matches.
///
/// No column stores it: the claim's own timestamp is the token. Both sides
/// read the value back from the database row, so the round trip through
/// `Double` is the same on each side.
enum WorkerClaimToken {
    static func token(assignedAt: Date) -> String {
        String(Int64((assignedAt.timeIntervalSince1970 * 1_000_000).rounded()))
    }
}

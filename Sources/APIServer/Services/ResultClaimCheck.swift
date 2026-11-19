// APIServer/Services/ResultClaimCheck.swift
//
// Result ingest accepts a runner's report only for the claim that runner
// still holds.

import Core
import Fluent
import FluentSQL
import Foundation
import SQLKit

/// Why a runner's result report no longer answers the row's current claim.
enum StaleClaimReason: String, Sendable {
    /// The submission row does not exist.
    case missingSubmission = "missing_submission"
    /// The report carries neither a runner id nor a claim token, so no
    /// claim can be matched to it.
    case missingWorkerID = "missing_worker_id"
    /// The row is not assigned (or completed) under a claim: a forced retest
    /// or the stuck-submission reaper re-queued it, or no runner claimed it.
    case notClaimed = "not_claimed"
    /// Another runner holds the row's current claim.
    case otherRunner = "other_runner"
    /// The same runner holds a later claim of the row than this report's.
    case earlierClaim = "earlier_claim"
}

/// The gate in front of result ingest (`ResultRoutes.reportResults`).
///
/// A forced "Retest all" (`bulkFlipStudentSubmissionsToPending` with `force`)
/// and the stuck-submission reaper both move an `assigned` row back to
/// `pending` while its runner may still be grading it under the old manifest.
/// That runner's report must not complete the re-queued row (the retest would
/// never run) or add a second result beside the retest's own. So a report is
/// accepted only when the row is still `assigned` to the reporting runner, or
/// `complete` under that runner's claim (a replay of a report whose response
/// was lost), and, when the report echoes a claim token, only for the claim
/// that token names.
///
/// A report without a token comes from a runner that predates
/// `Job.claimToken`: it is checked by runner id alone, which cannot tell the
/// same runner's two claims of one row apart. A report without a runner id
/// is checked by its token alone.
enum ResultClaimCheck {
    /// Reads the submission under a row lock and returns it when the report
    /// answers its current claim. Call inside the ingest transaction: the lock
    /// holds a concurrent retest's re-queue until the ingest commits, so the
    /// retest then re-queues the completed row instead of being overwritten.
    static func lockCurrentClaim(
        submissionID: String, workerID: String?, claimToken: String?, on tx: any Database
    ) async throws -> APISubmission {
        guard let sql = tx as? (any SQLDatabase) else {
            throw WorkerJobError.internalInconsistency(reason: "Result ingest needs a SQL database")
        }
        let row = try await sql.raw(
            """
            SELECT * FROM \(unsafeRaw: APISubmission.schema)
            WHERE id = \(bind: submissionID)
            FOR UPDATE
            """
        ).first()
        guard let row else {
            throw WorkerJobError.staleClaim(submissionID: submissionID, reason: .missingSubmission)
        }
        let submission = try row.decode(fluentModel: APISubmission.self)
        if let reason = staleReason(submission: submission, workerID: workerID, claimToken: claimToken) {
            throw WorkerJobError.staleClaim(submissionID: submissionID, reason: reason)
        }
        return submission
    }

    /// The decision alone, on a row already read: nil when the report
    /// answers the row's current claim.
    static func staleReason(
        submission: APISubmission, workerID: String?, claimToken: String?
    ) -> StaleClaimReason? {
        let claimed: Set<String> = [SubmissionStatus.assigned.rawValue, SubmissionStatus.complete.rawValue]
        guard claimed.contains(submission.status), submission.assignedAt != nil else { return .notClaimed }
        if let workerID, !workerID.isEmpty {
            guard let holder = submission.workerID else { return .notClaimed }
            guard holder == workerID else { return .otherRunner }
        } else if claimToken == nil {
            // No runner id and no token: nothing names a claim.
            return .missingWorkerID
        }
        // With no runner id the token alone must name the claim. A runner
        // always sends its id; the visual-regression seed sends only the
        // token, so it registers no runner on the admin dashboard
        // (Tools/visual-regression/seed.mjs). Every runner shares one HMAC
        // secret, so the id was never proof of identity; the token, which
        // only the claim's job payload carried, is the stronger check.
        if let claimToken {
            guard let assignedAt = submission.assignedAt,
                WorkerClaimToken.token(assignedAt: assignedAt) == claimToken
            else { return .earlierClaim }
        }
        return nil
    }
}

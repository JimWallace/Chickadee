// APIServer/Services/WorkerJobClaim.swift
//
// The claim step of POST /api/v1/worker/request: the idle-poll probe, the
// claim walk and the atomic claim itself (the Postgres `FOR UPDATE SKIP
// LOCKED` row lock, or the SQLite compare-and-set). Moved from
// WorkerJobRoutes.swift (#2774) with no behaviour change. It takes a
// database, the application and a logger, never a `Request`. The candidate
// walk it drives is in WorkerClaimEvaluation.swift.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

enum WorkerJobClaim {
    /// Finds and claims the best pending job for this runner.
    ///
    /// Structure (2026-07 audit): candidate collection, per-candidate
    /// requirement loading, and compatibility evaluation are all reads and
    /// run OUTSIDE the serialized claim section — holding the global
    /// WorkerClaimQueue (and a write transaction) across those queries
    /// multiplied the serialized section by the number of skipped candidates
    /// exactly when the queue was deepest. Only the claim itself is
    /// serialized, and it is an atomic compare-and-set
    /// (`UPDATE … WHERE status = 'pending'`), so a candidate another runner
    /// claimed between our scan and our claim matches zero rows and the walk
    /// simply moves to the next candidate.
    static func claimNextEligibleJob(
        body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?,
        db: any Database, application: Application, logger: Logger
    ) async throws -> ClaimedJob? {
        // Idle-poll short-circuit (2026-07 audit): most polls find nothing to
        // claim, yet each one previously entered the globally-serialized
        // claim section and opened a write transaction issuing 2–3 candidate
        // SELECTs. One cheap indexed existence probe (status prefix of
        // idx_submissions_status_kind_submitted_at) outside the serialized
        // section answers the empty case. Deliberately a fresh DB read, not
        // cached state: there is nothing to invalidate, it is correct across
        // processes, and a submission enqueued right after the probe is
        // simply seen by the runner's next poll — the same pickup latency
        // the poll cadence already implies. The claim transaction below
        // re-reads candidates, so this never affects claim atomicity.
        let hasPendingWork =
            try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .field(\.$id)
            .first() != nil
        guard hasPendingWork else { return nil }

        let evaluator = ClaimEvaluator(
            assignmentRequirements: application.assignmentRequirements,
            compatibilityMatcher: CompatibilityMatcher(),
            db: db,
            application: application,
            logger: logger
        )

        let candidates = try await collectClaimCandidates(on: db)
        return try await evaluateAndClaimCandidate(
            candidates: candidates,
            body: body,
            runnerProfile: runnerProfile,
            evaluator: evaluator,
            claim: {
                try await claimSubmission(id: $0, workerID: body.workerID, db: db, application: application)
            }
        )
    }

    /// Atomically claims one submission. Both backends claim only the
    /// already-evaluated candidate id — ordering and the requirement-
    /// compatibility walk stay in `evaluateAndClaimCandidate` — and both
    /// return nil on a lost race so the walk moves to the next candidate.
    ///
    /// **Postgres (#1172):** a short transaction takes a row lock with
    /// `SELECT … FOR UPDATE SKIP LOCKED` and updates the locked row. SKIP
    /// LOCKED means a row another claimer holds is skipped (nil) instead of
    /// waited on, so concurrent claims from any number of processes scale
    /// natively — no in-process serialization at all.
    ///
    /// **SQLite:** compare-and-set — the UPDATE's `status == pending` guard
    /// means concurrent claimers cannot both win (the same conditional-
    /// UPDATE idiom the MCP single-use token consumption uses), and the
    /// re-read confirms *this* worker won. The WorkerClaimQueue
    /// serializes in-process claim attempts so concurrent polls don't
    /// thrash SQLite's write lock.
    ///
    /// Internal (not private) so the claim semantics are directly testable —
    /// the lost-race path can't be triggered deterministically through the
    /// HTTP endpoint. ClaimCompareAndSetTests reach it through
    /// `WorkerJobRoutes.atomicallyClaimSubmission` and pin both backends:
    /// the same suite runs against SQLite (api-tests) and Postgres
    /// (api-tests-postgres).
    static func claimSubmission(
        id submissionID: String, workerID: String, db: any Database, application: Application
    ) async throws -> APISubmission? {
        if let sql = db as? (any SQLDatabase), sql.dialect.name == "postgresql" {
            return try await claimViaPostgresRowLock(id: submissionID, workerID: workerID, db: db)
        }
        return try await application.workerClaimQueue.run {
            // Three quick attempts: the claim queue already serializes this
            // process's claims, so a lock here is another process's write.
            try await withTransientDatabaseLockRetry(
                on: db, maxAttempts: 3, backoff: .fixed(.milliseconds(20))
            ) {
                try await APISubmission.query(on: db)
                    .filter(\.$id == submissionID)
                    .filter(\.$status == SubmissionStatus.pending.rawValue)
                    .set(\.$status, to: SubmissionStatus.assigned.rawValue)
                    .set(\.$workerID, to: workerID)
                    .set(\.$assignedAt, to: Date())
                    .update()
                guard
                    let fresh = try await APISubmission.find(submissionID, on: db),
                    fresh.status == SubmissionStatus.assigned.rawValue,
                    fresh.workerID == workerID
                else { return nil }
                return fresh
            }
        }
    }

    /// Postgres claim (#1172): lock the pending row (or bail if another
    /// claimer holds it / already flipped it), stamp it, and re-read inside
    /// the same transaction. The transaction spans exactly these three
    /// statements — candidate evaluation happens outside, before the call.
    private static func claimViaPostgresRowLock(
        id submissionID: String, workerID: String, db: any Database
    ) async throws -> APISubmission? {
        try await db.transaction { db in
            guard let sql = db as? (any SQLDatabase) else {
                throw WorkerJobError.internalInconsistency(
                    reason: "Postgres claim transaction did not expose SQLDatabase")
            }
            // SKIP LOCKED: a concurrently-locked row is skipped, not waited
            // on — the loser sees zero rows immediately and walks on to its
            // next candidate instead of queueing behind the winner.
            let locked = try await sql.raw(
                """
                SELECT id FROM submissions
                WHERE id = \(bind: submissionID)
                  AND status = \(bind: SubmissionStatus.pending.rawValue)
                FOR UPDATE SKIP LOCKED
                """
            ).first()
            guard locked != nil else { return nil }

            try await APISubmission.query(on: db)
                .filter(\.$id == submissionID)
                .set(\.$status, to: SubmissionStatus.assigned.rawValue)
                .set(\.$workerID, to: workerID)
                .set(\.$assignedAt, to: Date())
                .update()

            guard
                let fresh = try await APISubmission.find(submissionID, on: db),
                fresh.status == SubmissionStatus.assigned.rawValue,
                fresh.workerID == workerID
            else { return nil }
            return fresh
        }
    }
}

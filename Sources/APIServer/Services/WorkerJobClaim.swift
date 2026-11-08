// APIServer/Services/WorkerJobClaim.swift
//
// The claim step of POST /api/v1/worker/request: the idle-poll probe, the
// claim walk and the atomic claim itself (a `FOR UPDATE SKIP LOCKED` row
// lock). Moved from
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
    /// run OUTSIDE the claim transaction — holding a write transaction across
    /// those queries multiplied it by the number of skipped candidates. Only
    /// the claim itself is transactional, and a candidate another runner
    /// claimed between our scan and our claim yields nil, so the walk simply
    /// moves to the next candidate.
    static func claimNextEligibleJob(
        body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?,
        db: any Database, application: Application, logger: Logger
    ) async throws -> ClaimedJob? {
        // Idle-poll short-circuit (2026-07 audit): most polls find nothing to
        // claim, yet each one previously entered the claim section and opened
        // a write transaction issuing 2–3 candidate SELECTs. One cheap indexed
        // existence probe answers the empty case. Deliberately a fresh DB
        // read, not cached state: there is nothing to invalidate, it is
        // correct across processes, and a submission enqueued right after the
        // probe is simply seen by the runner's next poll — the same pickup
        // latency the poll cadence already implies. The claim transaction
        // below re-reads candidates, so this never affects claim atomicity.
        //
        // The sort on `kind` changes no answer; it is there for the planner.
        // Only an index led by `(status, kind)` returns that order without
        // sorting, from the pending range, so the probe reads the first
        // pending entry or an empty range, whatever the statistics say.
        // Unsorted, statistics taken during a backlog made it a sequential
        // scan, which read the whole table on every idle poll once the
        // backlog was gone (24 ms on a 225k-row table).
        let hasPendingWork =
            try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .sort(\.$kind, .ascending)
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

        // Load and walk one candidate group at a time, in priority order, and
        // stop at the first claim. In a backlog the first fresh student job
        // is nearly always claimable, so the later groups' queries and their
        // setups are never read (2026-11 performance audit).
        var loader = ClaimCandidateLoader(db: db)
        var walk = ClaimWalk(body: body, runnerProfile: runnerProfile, evaluator: evaluator)
        for group in ClaimCandidateGroup.allCases {
            let candidates = try await loader.load(group)
            guard !candidates.isEmpty else { continue }
            if let claimed = try await walk.claimFirst(
                in: candidates,
                claim: { try await claimSubmission(id: $0, workerID: body.workerID, db: db) })
            {
                return claimed
            }
        }
        await walk.finish()
        return nil
    }

    /// Atomically claims one submission (#1172). It claims only the
    /// already-evaluated candidate id — ordering and the requirement-
    /// compatibility walk stay in `evaluateAndClaimCandidate` — and returns
    /// nil on a lost race so the walk moves to the next candidate.
    ///
    /// A short transaction takes a row lock with `SELECT … FOR UPDATE SKIP
    /// LOCKED` and updates the locked row. SKIP LOCKED means a row another
    /// claimer holds is skipped (nil) instead of waited on, so concurrent
    /// claims from any number of processes scale natively — no in-process
    /// serialization at all.
    ///
    /// Internal (not private) so the claim semantics are directly testable —
    /// the lost-race path can't be triggered deterministically through the
    /// HTTP endpoint. ClaimCompareAndSetTests reach it through
    /// `WorkerJobRoutes.atomicallyClaimSubmission`.
    static func claimSubmission(
        id submissionID: String, workerID: String, db: any Database
    ) async throws -> APISubmission? {
        try await db.transaction { db in
            guard let sql = db as? (any SQLDatabase) else {
                throw WorkerJobError.internalInconsistency(
                    reason: "Claim transaction did not expose SQLDatabase")
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

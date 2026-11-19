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
import FluentSQL
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
    ///
    /// `reportsNoCompatibleRunner` is false for a held poll's later walks
    /// (`WorkerLongPoll`), so a held poll reports a blocked job once, not
    /// once per wake.
    static func claimNextEligibleJob(
        body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?,
        reportsNoCompatibleRunner: Bool,
        db: any Database, application: Application, logger: Logger
    ) async throws -> ClaimedJob? {
        guard try await hasPendingWork(on: db) else { return nil }

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
        if reportsNoCompatibleRunner {
            await walk.finish()
        }
        return nil
    }

    /// Whether any submission is pending: the idle-poll short-circuit.
    ///
    /// Most polls find nothing to claim, yet each one previously entered the
    /// claim section and opened a write transaction issuing 2–3 candidate
    /// SELECTs (2026-07 audit). One cheap indexed existence probe answers the
    /// empty case. Deliberately a fresh DB read, not cached state: there is
    /// nothing to invalidate, it is correct across processes, and a submission
    /// enqueued right after the probe is seen by the held poll's next claim
    /// attempt (`PendingWorkSignal`), or by the runner's next poll. The claim
    /// below re-reads candidates, so this never affects claim atomicity.
    ///
    /// The sort on `kind` changes no answer; it is there for the planner.
    /// Only an index led by `(status, kind)` returns that order without
    /// sorting, from the pending range, so the probe reads the first pending
    /// entry or an empty range, whatever the statistics say. Unsorted,
    /// statistics taken during a backlog made it a sequential scan, which read
    /// the whole table on every idle poll once the backlog was gone (24 ms on a
    /// 225k-row table).
    ///
    /// The probe runs through SQLKit: every runner slot polls up to once a
    /// second, and a Fluent query costs about twice the CPU of the same select
    /// (#2905). A database without SQL uses the same query through Fluent.
    static func hasPendingWork(on db: any Database) async throws -> Bool {
        guard let sql = db as? (any SQLDatabase) else {
            return try await APISubmission.query(on: db)
                .filter(\.$status == SubmissionStatus.pending.rawValue)
                .sort(\.$kind, .ascending)
                .field(\.$id)
                .first() != nil
        }
        return try await sql.select()
            .column("id")
            .from(APISubmission.schema)
            .where("status", .equal, SubmissionStatus.pending.rawValue)
            .orderBy("kind", .ascending)
            .limit(1)
            .first() != nil
    }

    /// How many submissions are pending, counted to at most `limit`. The
    /// held-poll watcher (`PendingWorkSignal`) compares one count with the
    /// next, once a second while a runner poll is held.
    ///
    /// The inner select sorts on `kind` and stops at `limit` for the reason
    /// `hasPendingWork` does: it keeps the planner on an index led by
    /// `(status, kind)` whatever the statistics say, and the cap bounds the
    /// read during a backlog. Past the cap the count stops growing, which
    /// costs a held poll at most its hold.
    static func pendingCount(on db: any Database, limit: Int = 1000) async throws -> Int {
        guard let sql = db as? (any SQLDatabase) else {
            return try await APISubmission.query(on: db)
                .filter(\.$status == SubmissionStatus.pending.rawValue)
                .count()
        }
        let row = try await sql.raw(
            """
            SELECT count(*) AS pending FROM (
              SELECT 1 FROM submissions
              WHERE status = \(bind: SubmissionStatus.pending.rawValue)
              ORDER BY kind
              LIMIT \(bind: limit)
            ) AS capped
            """
        ).first()
        return try row?.decode(column: "pending", as: Int.self) ?? 0
    }

    /// Atomically claims one submission (#1172). It claims only the
    /// already-evaluated candidate id — ordering and the requirement-
    /// compatibility walk stay in `ClaimWalk` — and returns nil on a lost race
    /// so the walk moves to the next candidate.
    ///
    /// One statement: an UPDATE whose target is a `SELECT … FOR UPDATE SKIP
    /// LOCKED` of the row while it is still pending, returning the claimed
    /// row. SKIP LOCKED means a row another claimer holds is skipped instead of
    /// waited on, and a row another claimer already moved out of pending
    /// matches nothing, so the loser gets no row at once and walks on.
    /// Concurrent claims from any number of processes scale with no in-process
    /// serialization. The statement is atomic on its own, so it needs no
    /// transaction: the claim used to be BEGIN, a lock, an UPDATE, a re-read
    /// and COMMIT, and a runner that lost races paid all five for each one
    /// (docs/database-performance.md).
    ///
    /// Internal (not private) so the claim semantics are directly testable —
    /// the lost-race path can't be triggered deterministically through the
    /// HTTP endpoint. ClaimCompareAndSetTests reach it through
    /// `WorkerJobRoutes.atomicallyClaimSubmission`.
    static func claimSubmission(
        id submissionID: String, workerID: String, db: any Database
    ) async throws -> APISubmission? {
        guard let sql = db as? (any SQLDatabase) else {
            throw WorkerJobError.internalInconsistency(reason: "The claim needs a SQL database")
        }
        let row = try await sql.raw(
            """
            UPDATE \(unsafeRaw: APISubmission.schema)
            SET status = \(bind: SubmissionStatus.assigned.rawValue),
                worker_id = \(bind: workerID),
                assigned_at = \(bind: Date())
            WHERE id = (
                SELECT id FROM \(unsafeRaw: APISubmission.schema)
                WHERE id = \(bind: submissionID)
                  AND status = \(bind: SubmissionStatus.pending.rawValue)
                FOR UPDATE SKIP LOCKED
            )
            RETURNING *
            """
        ).first()
        guard let row else { return nil }
        do {
            return try row.decode(fluentModel: APISubmission.self)
        } catch {
            // The UPDATE has committed, so a row that does not decode would
            // stay assigned to a runner that never receives it until the
            // stale-claim sweep. Hand it back to the queue first.
            try await sql.raw(
                """
                UPDATE \(unsafeRaw: APISubmission.schema)
                SET status = \(bind: SubmissionStatus.pending.rawValue), worker_id = NULL, assigned_at = NULL
                WHERE id = \(bind: submissionID)
                  AND status = \(bind: SubmissionStatus.assigned.rawValue)
                  AND worker_id = \(bind: workerID)
                """
            ).run()
            throw error
        }
    }
}

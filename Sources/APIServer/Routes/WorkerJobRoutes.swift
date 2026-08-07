import Core
import Fluent
import FluentSQLiteDriver
import Foundation
import SQLKit
import Vapor

struct WorkerJobRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let worker = routes.grouped("api", "v1", "worker")
        worker.post("request", use: requestJob)
        worker.post("heartbeat", use: heartbeat)
    }

    // MARK: - POST /api/v1/worker/request

    @Sendable
    func requestJob(req: Request) async throws -> Response {
        let body = try req.content.decode(WorkerActivityPayload.self)
        let seenAt = Date()

        if let conflict = try await rejectIfWorkerIDConflicts(req: req, body: body) {
            return conflict
        }

        let runnerProfile = try await recordRunnerCheckIn(req: req, body: body, seenAt: seenAt, reason: .poll)

        guard let claimed = try await claimNextEligibleJob(req: req, body: body, runnerProfile: runnerProfile) else {
            return Response(status: .noContent)
        }

        await req.application.workerActivityStore.incrementAssignedJobs(for: body.workerID)
        await recordJobAssignmentDiagnostics(req: req, body: body, claimed: claimed)

        let job = try await buildJobPayload(req: req, body: body, claimed: claimed)
        return try encodeJobResponse(job)
    }

    /// Rejects the request when the workerID is already in use by a *different*
    /// host within the activity TTL.  Same-hostname re-polls are treated as a
    /// process restart, not a conflict.
    private func rejectIfWorkerIDConflicts(
        req: Request, body: WorkerActivityPayload
    ) async throws -> Response? {
        // 3× the runner's max backoff of 30 s = 90 s.
        let conflictTTL: TimeInterval = 90
        let isConflict = await req.application.workerActivityStore.isConflict(
            workerID: body.workerID,
            hostname: body.hostname,
            ttlSeconds: conflictTTL
        )
        guard isConflict else { return nil }
        struct ConflictBody: Content { let error: String }
        let msg =
            "workerID \"\(body.workerID)\" is already in use by an active runner. "
            + "Choose a different --worker-id or wait for the existing runner to time out."
        return try Response(
            status: .conflict,
            headers: ["Content-Type": "application/json"],
            body: .init(data: JSONEncoder().encode(ConflictBody(error: msg)))
        )
    }

    /// Marks the runner active, upserts its capability profile, and records
    /// the check-in — the one check-in block shared by the poll and heartbeat
    /// endpoints, which only differ in which activity timestamp advances and
    /// the recorded reason (#1118; the two ~30-line copies had already been
    /// drifting). Returns the resolved capability profile (nil if none).
    private func recordRunnerCheckIn(
        req: Request, body: WorkerActivityPayload, seenAt: Date, reason: RunnerCheckInReason
    ) async throws -> RunnerCapabilityProfile? {
        await req.application.workerActivityStore.markActive(
            workerID: body.workerID,
            hostname: body.hostname,
            runnerVersion: body.runnerVersion,
            maxConcurrentJobs: body.maxConcurrentJobs,
            activeJobs: body.activeJobs,
            lastPollAt: reason == .poll ? seenAt : nil,
            lastHeartbeatAt: reason == .heartbeat ? seenAt : nil
        )
        let profileUpsert = try await req.application.runnerProfiles.registerOrUpdate(
            runnerID: body.workerID,
            displayName: body.hostname,
            profile: body.profile,
            seenAt: seenAt,
            on: req.db
        )
        if let profile = profileUpsert.profile, let event = profileUpsert.event {
            req.application.diagnostics.recordRunnerProfileEvent(
                profile: profile,
                event: event,
                logger: req.logger
            )
        }
        if let snapshot = await req.application.workerActivityStore.snapshot(for: body.workerID) {
            await req.application.diagnostics.recordRunnerCheckIn(
                snapshot: snapshot,
                reason: reason,
                on: req.db,
                logger: req.logger
            )
        }
        return profileUpsert.profile?.capabilityProfile
    }

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
    private func claimNextEligibleJob(
        req: Request, body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?
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
            try await APISubmission.query(on: req.db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .field(\.$id)
            .first() != nil
        guard hasPendingWork else { return nil }

        let evaluator = ClaimEvaluator(
            assignmentRequirements: req.application.assignmentRequirements,
            compatibilityMatcher: CompatibilityMatcher()
        )

        let candidates = try await collectClaimCandidates(on: req.db)
        return try await evaluateAndClaimCandidate(
            candidates: candidates,
            req: req,
            body: body,
            runnerProfile: runnerProfile,
            evaluator: evaluator
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
    /// re-read confirms *this* worker won. The WorkerClaimQueue actor
    /// serializes in-process claim attempts so concurrent polls don't
    /// thrash SQLite's write lock.
    ///
    /// Internal (not private) so the claim semantics are directly testable —
    /// the lost-race path can't be triggered deterministically through the
    /// HTTP endpoint. ClaimCompareAndSetTests pin both backends: the same
    /// suite runs against SQLite (api-tests) and Postgres
    /// (api-tests-postgres).
    func atomicallyClaimSubmission(
        id submissionID: String, req: Request, body: WorkerActivityPayload
    ) async throws -> APISubmission? {
        if let sql = req.db as? SQLDatabase, sql.dialect.name == "postgresql" {
            return try await claimViaPostgresRowLock(id: submissionID, req: req, body: body)
        }
        return try await req.application.workerClaimQueue.run {
            try await retrySQLiteBusyClaim {
                try await APISubmission.query(on: req.db)
                    .filter(\.$id == submissionID)
                    .filter(\.$status == SubmissionStatus.pending.rawValue)
                    .set(\.$status, to: SubmissionStatus.assigned.rawValue)
                    .set(\.$workerID, to: body.workerID)
                    .set(\.$assignedAt, to: Date())
                    .update()
                guard
                    let fresh = try await APISubmission.find(submissionID, on: req.db),
                    fresh.status == SubmissionStatus.assigned.rawValue,
                    fresh.workerID == body.workerID
                else { return nil }
                return fresh
            }
        }
    }

    /// Postgres claim (#1172): lock the pending row (or bail if another
    /// claimer holds it / already flipped it), stamp it, and re-read inside
    /// the same transaction. The transaction spans exactly these three
    /// statements — candidate evaluation happens outside, before the call.
    private func claimViaPostgresRowLock(
        id submissionID: String, req: Request, body: WorkerActivityPayload
    ) async throws -> APISubmission? {
        try await req.db.transaction { db in
            guard let sql = db as? SQLDatabase else {
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
                .set(\.$workerID, to: body.workerID)
                .set(\.$assignedAt, to: Date())
                .update()

            guard
                let fresh = try await APISubmission.find(submissionID, on: db),
                fresh.status == SubmissionStatus.assigned.rawValue,
                fresh.workerID == body.workerID
            else { return nil }
            return fresh
        }
    }

    /// Records "job assigned" diagnostics outside the claim transaction so
    /// `req.application` is safely accessible.
    private func recordJobAssignmentDiagnostics(
        req: Request, body: WorkerActivityPayload, claimed: ClaimedJob
    ) async {
        await req.application.diagnostics.recordJobAssigned(
            submission: claimed.submission, runnerVersion: body.runnerVersion,
            on: req.db, logger: req.logger
        )
        req.application.diagnostics.recordCompatibleJobAssignment(
            submission: claimed.submission,
            assignmentID: claimed.assignmentID,
            runnerID: body.workerID,
            requirements: claimed.requirementSpec,
            logger: req.logger
        )
    }

    /// Builds the `Job` payload returned to the runner — resolves the
    /// per-(student, assignment) personalization seed and constructs the
    /// submission/testsetup download URLs.
    private func buildJobPayload(
        req: Request, body: WorkerActivityPayload, claimed: ClaimedJob
    ) async throws(WorkerJobError) -> Job {
        let submission = claimed.submission
        let setup = claimed.setup
        let base = resolvedWorkerBaseURL(req: req)

        // Validation submissions are pre-materialized at enqueue
        // (`materializeValidationGrading`): the seed + resolved expression values
        // are cached on the row, so we read them here instead of re-running the
        // personalization evaluator on this hot (poll) path — and the answer-key
        // notebook, `_ck_inputs.py`, and `CHICKADEE_ASSIGNMENT_SEED` all derive
        // from one seed. Student submissions have no cache and resolve live.
        let materialization = submission.decodedMaterialization()

        // Per-(student, assignment) seed for personalized inputs (issue #461, Phase 1).
        // Generated lazily on first grading attempt; stable for the lifetime of the
        // (user, assignment) pair. Nil when the submission has no associated user
        // (legacy / unauthenticated path) or no assignment row was matched.
        var assignmentSeed: String?
        if let materialization {
            assignmentSeed = materialization.seedHex
        } else if let userID = submission.userID, let resolvedAssignmentID = claimed.assignmentID {
            do {
                assignmentSeed = try await AssignmentSeedStore.ensureSeed(
                    userID: userID,
                    assignmentID: resolvedAssignmentID,
                    on: req.db
                )
            } catch {
                req.logger.error("Failed to ensure assignment seed: \(error)")
                // Grading continues without a seed — non-personalized assignments are unaffected.
            }
        }

        guard let submissionID = submission.id, let setupID = setup.id else {
            throw WorkerJobError.internalInconsistency(reason: "Claimed submission or test setup missing id")
        }
        let downloadVersion = await testSetupDownloadVersion(for: setup, req: req)
        guard
            let submissionURL = URL(string: "\(base)/api/v1/worker/submissions/\(submissionID)/download"),
            let testSetupURL = URL(
                string: "\(base)/api/v1/worker/testsetups/\(setupID)/download?v=\(downloadVersion)"
            )
        else {
            throw WorkerJobError.internalInconsistency(reason: "Failed to build worker download URLs from base=\(base)")
        }

        // The assignment's language selects how per-student inputs are rendered
        // (`_ck_inputs.py` / `_ck_inputs.R` / `_ck_inputs.lua`) and which
        // interpreter evaluated the expressions. Resolved from the manifest (any
        // non-default graded script → that language, e.g. `.lua` → Lua); stamped
        // on the Job so the worker materializes the right file.
        let language = AssignmentLanguage.resolve(for: setup, manifest: claimed.manifest)

        // Resolve per-student personalization inputs (issue #461) for this seed,
        // server-side, so the worker can bind them in generated scripts via
        // `_ck_inputs.{py,R}`. Shared with the browser seed endpoint via
        // `gradingInputs` so the two grading paths resolve identically. For a
        // pre-materialized validation submission we use the cached values
        // (no re-eval on this hot path); otherwise we resolve live.
        let personalizedInputs: [String: String]?
        if let materialization {
            personalizedInputs = materialization.inputs.isEmpty ? nil : materialization.inputs
        } else {
            let supportDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
            personalizedInputs = await PersonalizationSubstitution.gradingInputs(
                manifest: claimed.manifest, seedHex: assignmentSeed, supportFilesDirectory: supportDir,
                language: language)
        }

        // Resolve per-student dataset slices (Phase 1 datasets) for this seed.
        // Cheap and deterministic (a file read + in-memory sample, no
        // subprocess), so we resolve live for both student and validation
        // submissions rather than caching it on the materialization row. A
        // strict no-op for every assignment that declares no datasets — which is
        // all of them until the dataset editor ships — so existing jobs are
        // byte-identical to before. The runner-sanitized manifest below drops
        // the dataset specs; only the resolved bytes travel, in `personalizedFiles`.
        let datasetSharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
        let personalizedFiles = DatasetResolver.resolve(
            manifest: claimed.manifest, seedHex: assignmentSeed, sourceDirectory: datasetSharedDir)

        return Job(
            submissionID: submissionID,
            testSetupID: setupID,
            attemptNumber: submission.attemptNumber ?? 1,
            submissionURL: submissionURL,
            testSetupURL: testSetupURL,
            manifest: claimed.manifest.runnerSanitized(),
            submissionFilename: submission.filename,
            assignmentSeed: assignmentSeed,
            personalizedInputs: personalizedInputs,
            personalizedFiles: personalizedFiles,
            language: language
        )
    }

    private func encodeJobResponse(_ job: Job) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    @Sendable
    func heartbeat(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(WorkerActivityPayload.self)
        _ = try await recordRunnerCheckIn(req: req, body: body, seenAt: Date(), reason: .heartbeat)
        return .ok
    }
}

/// Output of `claimNextEligibleJob` — the submission + setup pair that was
/// atomically claimed inside the transaction, plus the assignment context
/// needed for downstream diagnostics and `Job` payload construction.
private struct ClaimedJob {
    let submission: APISubmission
    let setup: APITestSetup
    let manifest: TestProperties
    let assignmentID: UUID?
    let requirementSpec: AssignmentRequirementSpec?
}

/// A candidate that was skipped because the runner's profile didn't match the
/// assignment's requirements.  We keep the *first* one we see so that, when no
/// candidate is claimable, we can emit a single "no compatible runner
/// available" diagnostic instead of one per scanned candidate.
private struct BlockedCandidate {
    let submission: APISubmission
    let assignmentID: UUID?
    let requirements: AssignmentRequirementSpec?
    let result: CompatibilityResult
}

/// Loads the ordered list of claim candidates (plain reads, outside the
/// serialized claim section — the compare-and-set claim re-checks pending).
/// Fresh student work (retestedAt == nil) is claimed before any retest
/// (retestedAt != nil), so a manifest-revision sweep can't starve students who
/// are actively submitting (#427). Within each group, oldest submittedAt wins.
/// Validation submissions are always worker-mode (instructors validate via worker)
/// and are appended after student work.
private func collectClaimCandidates(
    on db: Database
) async throws -> [(APISubmission, APITestSetup, TestProperties)] {
    // Cap the scan: a poll claims exactly one job, so walking the entire
    // pending queue (potentially tens of thousands of rows after a retest
    // fan-out) inside the globally-serialized claim transaction collapsed
    // claim throughput exactly when the queue was deepest (June 2026 audit,
    // P1.3). The cap only matters when the first `claimCandidateScanLimit`
    // candidates are all requirement-incompatible with this runner — the next
    // poll retries, and most assignments carry no runner requirements at all.
    //
    // Fresh student work (retestedAt == nil) keeps absolute priority over
    // retests (#427) by querying the two groups separately — which also
    // replaces the old full-scan + in-memory re-sort.
    let claimCandidateScanLimit = 50
    var studentSubmissions = try await APISubmission.query(on: db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .filter(\.$kind == APISubmission.Kind.student)
        .filter(\.$retestedAt == nil)
        .sort(\.$submittedAt, .ascending)
        .limit(claimCandidateScanLimit)
        .all()
    if studentSubmissions.count < claimCandidateScanLimit {
        studentSubmissions += try await APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$retestedAt != nil)
            .sort(\.$submittedAt, .ascending)
            .limit(claimCandidateScanLimit - studentSubmissions.count)
            .all()
    }

    // Many pending submissions often target the same test setup (e.g. a class
    // submitting to one assignment before a deadline). Resolve each setup +
    // decoded manifest once and reuse it, rather than re-querying the row and
    // re-decoding the identical manifest JSON for every candidate.
    var resolvedBySetupID: [String: (APITestSetup, TestProperties)] = [:]
    var candidates: [(APISubmission, APITestSetup, TestProperties)] = []

    for candidate in studentSubmissions {
        if let cached = resolvedBySetupID[candidate.testSetupID] {
            candidates.append((candidate, cached.0, cached.1))
            continue
        }
        guard let setup = try await APITestSetup.find(candidate.testSetupID, on: db) else { continue }
        guard let manifest = decodeManifest(from: Data(setup.manifest.utf8)) else { continue }
        resolvedBySetupID[candidate.testSetupID] = (setup, manifest)
        // Accept both worker-mode and browser-mode pending submissions.
        // Browser-mode submissions become pending when the client-side runner
        // fails or freezes (the `browser-failover` endpoint enqueues them) or
        // when an instructor retests; the worker serves as a backstop that runs
        // the .py test scripts natively via python3.
        candidates.append((candidate, setup, manifest))
    }

    let pendingValidation = try await APISubmission.query(on: db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .ascending)
        .limit(claimCandidateScanLimit)
        .all()

    for validation in pendingValidation {
        if let cached = resolvedBySetupID[validation.testSetupID] {
            candidates.append((validation, cached.0, cached.1))
            continue
        }
        guard let valSetup = try await APITestSetup.find(validation.testSetupID, on: db) else {
            throw WorkerJobError.testSetupNotFound(id: validation.testSetupID)
        }
        let valManifest = try ManifestCodec.decoder.decode(
            TestProperties.self, from: Data(valSetup.manifest.utf8))
        resolvedBySetupID[validation.testSetupID] = (valSetup, valManifest)
        candidates.append((validation, valSetup, valManifest))
    }

    return candidates
}

/// Walks the ordered candidate list, checks each against the runner's
/// capability profile, and atomically claims the first compatible one that is
/// still pending.  All evaluation (requirement queries, compatibility
/// matching, diagnostics) happens outside the serialized claim section; only
/// the compare-and-set claim itself is serialized.  A candidate that another
/// runner claimed since the scan fails its CAS and the walk continues.  When
/// no candidate is claimable, emits a single "no compatible runner available"
/// diagnostic for the first blocked candidate we saw and returns nil.
/// ClaimEvaluator bundles the per-claim collaborators that don't change
/// between candidates, so the evaluation helper stays under the
/// parameter-count cap.
private struct ClaimEvaluator {
    let assignmentRequirements: AssignmentRequirementService
    let compatibilityMatcher: CompatibilityMatcher
}

extension WorkerJobRoutes {
    fileprivate func evaluateAndClaimCandidate(
        candidates: [(APISubmission, APITestSetup, TestProperties)],
        req: Request,
        body: WorkerActivityPayload,
        runnerProfile: RunnerCapabilityProfile?,
        evaluator: ClaimEvaluator
    ) async throws -> ClaimedJob? {
        var blockedCandidate: BlockedCandidate?

        for (submission, setup, manifest) in candidates {
            let loadedRequirements = try await evaluator.assignmentRequirements.loadRequirement(
                for: submission, on: req.db)
            let requirementSpec = loadedRequirements.requirement?.requirementSpec

            req.application.diagnostics.recordAssignmentRequirementsLoaded(
                submission: submission,
                assignmentID: loadedRequirements.assignmentID,
                requirements: requirementSpec,
                logger: req.logger
            )

            let capabilityResult = evaluator.compatibilityMatcher.evaluate(
                runnerProfile: runnerProfile,
                requirements: requirementSpec
            )
            // Fold the manifest's optional `minimumRunnerVersion` gate into the
            // same verdict so a version block rides the existing diagnostics /
            // guard / blocked-candidate path.  Use the *merged* result below,
            // not `capabilityResult`, or the diagnostics would report
            // "compatible" while the job is actually blocked on version.
            let compatibilityResult = RunnerVersionGate.combine(
                capabilityResult,
                RunnerVersionGate.evaluate(
                    runnerVersion: body.runnerVersion,
                    minimumRunnerVersion: manifest.minimumRunnerVersion
                )
            )
            await req.application.diagnostics.recordCompatibilityDecision(
                submission: submission,
                assignmentID: loadedRequirements.assignmentID,
                runnerID: body.workerID,
                requirements: requirementSpec,
                result: compatibilityResult,
                logger: req.logger
            )

            guard compatibilityResult.isCompatible else {
                if blockedCandidate == nil {
                    blockedCandidate = BlockedCandidate(
                        submission: submission,
                        assignmentID: loadedRequirements.assignmentID,
                        requirements: requirementSpec,
                        result: compatibilityResult
                    )
                }
                continue
            }

            guard let submissionID = submission.id,
                let claimed = try await atomicallyClaimSubmission(id: submissionID, req: req, body: body)
            else {
                // Lost the claim race (or a malformed row) — the next
                // candidate may still be ours.
                continue
            }

            return ClaimedJob(
                submission: claimed,
                setup: setup,
                manifest: manifest,
                assignmentID: loadedRequirements.assignmentID,
                requirementSpec: requirementSpec
            )
        }

        if let blockedCandidate {
            await req.application.diagnostics.recordNoCompatibleRunnerAvailable(
                submission: blockedCandidate.submission,
                assignmentID: blockedCandidate.assignmentID,
                runnerID: body.workerID,
                requirements: blockedCandidate.requirements,
                result: blockedCandidate.result,
                logger: req.logger
            )
        }
        return nil
    }
}

private func resolvedWorkerBaseURL(req: Request) -> String {
    if let explicit = req.application.appConfig.workers.publicBaseURL {
        return explicit
    }

    // Prefer forwarded headers (proxy/LB), then Host from the runner request.
    let forwardedHost = firstHeaderValue(req.headers, name: .init("X-Forwarded-Host"))
    let hostHeader = firstHeaderValue(req.headers, name: .host)
    let scheme = firstHeaderValue(req.headers, name: .init("X-Forwarded-Proto")) ?? "http"

    if let host = forwardedHost ?? hostHeader, !host.isEmpty {
        return "\(scheme)://\(host)"
    }

    // Last-resort fallback from server bind config.
    let bindHost = normalizedWorkerBindHost(req.application.http.server.configuration.hostname)
    let port = req.application.http.server.configuration.port
    return "\(scheme)://\(bindHost):\(port)"
}

private func firstHeaderValue(_ headers: HTTPHeaders, name: HTTPHeaders.Name) -> String? {
    guard let value = headers.first(name: name) else { return nil }
    let firstCSV = value.split(separator: ",").first.map(String.init) ?? value
    let cleaned = firstCSV.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

private func normalizedWorkerBindHost(_ raw: String) -> String {
    let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty || host == "0.0.0.0" || host == "::" {
        return "localhost"
    }
    return host
}

/// Memoizes the (manifest, zip) content hash per setup so the hot claim path
/// doesn't re-read and re-SHA the full setup zip for every job handed out
/// (June 2026 audit, P1.8). Keyed on manifest text + zip (path, size, mtime):
/// suite edits rewrite both the manifest and the zip, so any real change
/// invalidates the entry.
private actor TestSetupDownloadVersionCache {
    static let shared = TestSetupDownloadVersionCache()

    private var entries: [String: (key: Key, version: String)] = [:]

    func cachedVersion(setupID: String, key: Key) -> String? {
        guard let cached = entries[setupID], cached.key == key else { return nil }
        return cached.version
    }

    func store(setupID: String, key: Key, version: String) {
        entries[setupID] = (key, version)
    }

    static func makeKey(manifest: String, zipPath: String) -> Key {
        let attributes = try? FileManager.default.attributesOfItem(atPath: zipPath)
        return Key(
            manifest: manifest,
            zipPath: zipPath,
            zipSize: (attributes?[.size] as? UInt64) ?? 0,
            zipModified: (attributes?[.modificationDate] as? Date) ?? .distantPast)
    }

    struct Key: Hashable, Sendable {
        let manifest: String
        let zipPath: String
        let zipSize: UInt64
        let zipModified: Date
    }
}

private func testSetupDownloadVersion(for setup: APITestSetup, req: Request) async -> String {
    let setupID = setup.id ?? setup.zipPath
    let manifest = setup.manifest
    let zipPath = setup.zipPath
    let key = TestSetupDownloadVersionCache.makeKey(manifest: manifest, zipPath: zipPath)

    if let cached = await TestSetupDownloadVersionCache.shared.cachedVersion(setupID: setupID, key: key) {
        return cached
    }

    // Cache miss (first claim after any suite edit): the zip is hashed in
    // streamed 1 MiB chunks on the thread pool (#1160) — the old
    // Data(contentsOf:) pulled a whole dataset-heavy setup zip into heap
    // inside the actor, on the claim path. Digest is byte-identical to the
    // old manifest+"|zip="+bytes concatenation, so versions (and runner
    // download caches) carry across the change.
    let prefix = Data(manifest.utf8) + Data("|zip=".utf8)
    let digest =
        (try? await runBlocking(on: req) {
            sha256HexDigest(prefix: prefix, contentsOfFile: zipPath)
        }).flatMap { $0 }
    let version = String((digest ?? sha256HexDigest(Data(manifest.utf8))).prefix(16))
    await TestSetupDownloadVersionCache.shared.store(setupID: setupID, key: key, version: version)
    return version
}

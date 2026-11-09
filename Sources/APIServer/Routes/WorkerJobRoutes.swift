import Core
import Fluent
import Foundation
import SQLKit
import Vapor

struct WorkerJobRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let worker = routes.grouped("api", "v1", "worker")
        worker.post("request", use: requestJob)
        worker.post("heartbeat", use: heartbeat)
    }

    // MARK: - POST /api/v1/worker/request

    @Sendable
    func requestJob(req: Request) async throws -> Response {
        let body = try await req.decodeContent(WorkerActivityPayload.self)
        let seenAt = Date()

        if let conflict = try await rejectIfWorkerIDConflicts(req: req, body: body) {
            return conflict
        }

        let runnerProfile = try await recordRunnerCheckIn(req: req, body: body, seenAt: seenAt, reason: .poll)

        guard let holdSeconds = WorkerLongPoll.grantedHoldSeconds(requested: body.longPollSeconds) else {
            guard
                let claimed = try await claimNextEligibleJob(
                    req: req, body: body, runnerProfile: runnerProfile, reportsNoCompatibleRunner: true)
            else {
                return Response(status: .noContent)
            }
            return try await respondWithClaimedJob(req: req, body: body, claimed: claimed)
        }

        // The runner asked for a held poll. Claim, and if nothing is
        // claimable, wait for pending work to appear and claim again, until
        // the hold ends or the server shuts down. The generation is read
        // before each claim, so work that arrives during the claim walk ends
        // the wait at once.
        //
        // Only the first walk reports a job no compatible runner can take.
        // Every wake walks again, and a report per wake would count walks,
        // not blocked jobs. The time spent waiting is recorded on the request
        // so the request timing measures the server's work, not the hold.
        let signal = req.application.pendingWorkSignal
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(holdSeconds)
        var isFirstWalk = true
        while true {
            let generation = await signal.currentGeneration
            if let claimed = try await claimNextEligibleJob(
                req: req, body: body, runnerProfile: runnerProfile, reportsNoCompatibleRunner: isFirstWalk)
            {
                return try await respondWithClaimedJob(req: req, body: body, claimed: claimed)
            }
            isFirstWalk = false
            if await signal.isClosed || clock.now >= deadline {
                break
            }
            let waitStarted = clock.now
            await signal.wait(after: generation, until: deadline)
            req.addHeldPollWait(waitStarted.duration(to: clock.now))
            if await signal.isClosed {
                break
            }
        }
        return Response(status: .noContent, headers: [WorkerLongPoll.heldHeader: "1"])
    }

    /// Records the assignment and returns the claimed job to the runner.
    private func respondWithClaimedJob(
        req: Request, body: WorkerActivityPayload, claimed: ClaimedJob
    ) async throws -> Response {
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

    /// Finds and claims the best pending job for this runner. The claim
    /// logic is in `WorkerJobClaim` (#2774).
    private func claimNextEligibleJob(
        req: Request, body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?,
        reportsNoCompatibleRunner: Bool
    ) async throws -> ClaimedJob? {
        try await WorkerJobClaim.claimNextEligibleJob(
            body: body, runnerProfile: runnerProfile, reportsNoCompatibleRunner: reportsNoCompatibleRunner,
            db: req.db, application: req.application, logger: req.logger)
    }

    /// Forwards to `WorkerJobClaim.claimSubmission`. ClaimCompareAndSetTests
    /// call the claim through the route type.
    func atomicallyClaimSubmission(
        id submissionID: String, req: Request, body: WorkerActivityPayload
    ) async throws -> APISubmission? {
        try await WorkerJobClaim.claimSubmission(
            id: submissionID, workerID: body.workerID, db: req.db)
    }

    /// Records "job assigned" diagnostics outside the claim transaction so
    /// `req.application` is safely accessible.
    private func recordJobAssignmentDiagnostics(
        req: Request, body: WorkerActivityPayload, claimed: ClaimedJob
    ) async {
        // The claim walk already resolved the course (the setup row) and the
        // assignment (the requirement lookup), so the recorder need not
        // query them again.
        await req.application.diagnostics.recordJobAssigned(
            submission: claimed.submission, runnerVersion: body.runnerVersion,
            context: SubmissionDiagnosticsContext(courseID: claimed.setup.courseID, assignmentID: claimed.assignmentID),
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

        // The per-(student, course) seed for course-scoped datasets
        // (docs/datasets-course-library.md, slice 4). A pinned run (a solution
        // variant or a spare) carries its own; a student's run resolves it.
        // Nil for an assignment with no course-scoped dataset, and for a job
        // with no student, which then grades the pool like every other
        // ownerless job.
        var courseSeed: String?
        if let materialization {
            courseSeed = materialization.courseSeedHex
        } else {
            do {
                courseSeed = try await CourseSeedStore.seedIfNeeded(
                    manifest: claimed.manifest, userID: submission.userID, courseID: setup.courseID, on: req.db)
            } catch {
                // Grading on, without it, would grade a course-scoped dataset
                // on per-assignment rows the student never saw. Failing the
                // payload leaves the job to the stale-claim sweep instead.
                req.logger.error("Failed to ensure course seed: \(error)")
                throw WorkerJobError.internalInconsistency(reason: "Could not resolve the course seed")
            }
        }

        // A class composite's slot travels with the inputs
        // (docs/class-composite.md): slot 0 for a validation run, the
        // reference row's slot for a reference job, the student's dealt slot
        // otherwise. Asked before the deal number, because it deals the slot
        // that a partition's deal number reads on a composite.
        let compositeInputs = await CompositeSlots.jobInputs(
            manifest: claimed.manifest, courseID: setup.courseID, assignmentID: claimed.assignmentID,
            submission: submission, on: req.db)

        // The deal number for the partition datasets
        // (docs/datasets-course-library.md §4.11). A pinned run carries its
        // own, a reference job takes its slot, any other run takes its kind's
        // number, and a job with no student has none, so it grades the whole
        // file.
        let dealNumber: Int?
        do {
            dealNumber = try await DatasetDeals.jobDealNumber(
                manifest: claimed.manifest, courseID: setup.courseID, assignmentID: claimed.assignmentID,
                submission: submission, pinned: materialization?.dealNumber, on: req.db)
        } catch {
            // Grading on, without it, would grade a partition on the whole
            // file the student never saw. As for the course seed, the
            // stale-claim sweep retries the job.
            req.logger.error("Failed to deal a dataset part: \(error)")
            throw WorkerJobError.internalInconsistency(reason: "Could not resolve the dataset deal number")
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
        let language = AssignmentLanguage.resolve(manifest: claimed.manifest)

        // Resolve per-student dataset slices (Phase 1 datasets) for this seed.
        // Cheap and deterministic (a file read + in-memory sample, no
        // subprocess), so we resolve live for both student and validation
        // submissions rather than caching it on the materialization row. A
        // strict no-op for every assignment that declares no datasets — which is
        // all of them until the dataset editor ships — so existing jobs are
        // byte-identical to before. The runner-sanitized manifest below drops
        // the dataset specs; only the resolved bytes travel, in `personalizedFiles`.
        // Resolved first, on the thread pool (it reads files, #1156), so the
        // expressions below read the same slices instead of resolving again.
        let datasetSharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
        let manifest = claimed.manifest
        let resolveSlices = { @Sendable [assignmentSeed, courseSeed] in
            DatasetResolver.resolve(
                manifest: manifest, seedHex: assignmentSeed, courseSeedHex: courseSeed, dealNumber: dealNumber,
                sourceDirectory: datasetSharedDir)
        }
        let personalizedFiles: [String: String]?
        do {
            personalizedFiles = try await runBlocking(resolveSlices)
        } catch {
            // The pool refuses work only while the server shuts down. Resolve
            // here instead, so the claim fails no more often than it did.
            personalizedFiles = resolveSlices()
        }

        // Resolve per-student personalization inputs (issue #461) for this seed,
        // server-side, so the worker can bind them in generated scripts via
        // `_ck_inputs.{py,R}`. Shared with the browser seed endpoint via
        // `gradingInputs` so the two grading paths resolve identically. For a
        // pre-materialized validation submission we use the cached values
        // (no re-eval on this hot path); otherwise we resolve live.
        var personalizedInputs: [String: String]?
        if let materialization {
            personalizedInputs = materialization.inputs.isEmpty ? nil : materialization.inputs
        } else {
            personalizedInputs = await PersonalizationSubstitution.gradingInputs(
                manifest: claimed.manifest, seedHex: assignmentSeed, courseSeedHex: courseSeed,
                dealNumber: dealNumber, supportFilesDirectory: datasetSharedDir, language: language,
                datasetSlices: .resolved(personalizedFiles))
        }
        personalizedInputs = CompositeSlots.merged(personalizedInputs, with: compositeInputs)

        let opponentSet = try await JobOpponentSelection.jobOpponentSet(
            manifest: claimed.manifest, submission: submission, base: base, on: req.db)
        return Job(
            submissionID: submissionID,
            testSetupID: setupID,
            attemptNumber: submission.attemptNumber ?? 1,
            submissionURL: submissionURL,
            testSetupURL: testSetupURL,
            manifest: claimed.manifest.runnerManifest(),
            submissionFilename: submission.filename,
            assignmentSeed: assignmentSeed,
            personalizedInputs: personalizedInputs,
            personalizedFiles: personalizedFiles,
            language: language,
            opponent: opponentSet.opponent,
            opponents: opponentSet.opponents
        )
    }

    /// Forwards to `JobOpponentSelection.jobOpponentSet` (#2774). The
    /// activity tests call it through the route type.
    static func jobOpponentSet(
        manifest: TestProperties, submission: APISubmission, base: String, on db: any Database
    ) async throws(WorkerJobError) -> (opponent: JobOpponent?, opponents: [JobOpponent]?) {
        try await JobOpponentSelection.jobOpponentSet(
            manifest: manifest, submission: submission, base: base, on: db)
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
        let body = try await req.decodeContent(WorkerActivityPayload.self)
        _ = try await recordRunnerCheckIn(req: req, body: body, seenAt: Date(), reason: .heartbeat)
        return .ok
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
        (try? await runBlocking {
            sha256HexDigest(prefix: prefix, contentsOfFile: zipPath)
        }).flatMap(\.self)
    let version = String((digest ?? sha256HexDigest(Data(manifest.utf8))).prefix(16))
    await TestSetupDownloadVersionCache.shared.store(setupID: setupID, key: key, version: version)
    return version
}

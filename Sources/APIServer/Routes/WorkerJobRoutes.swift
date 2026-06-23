import Core
import Fluent
import FluentSQLiteDriver
import Foundation
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

        let runnerProfile = try await recordPollActivity(req: req, body: body, seenAt: seenAt)

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

    /// Marks the runner active, upserts its capability profile, and records the
    /// check-in.  Returns the resolved capability profile (nil if none).
    private func recordPollActivity(
        req: Request, body: WorkerActivityPayload, seenAt: Date
    ) async throws -> RunnerCapabilityProfile? {
        await req.application.workerActivityStore.markActive(
            workerID: body.workerID,
            hostname: body.hostname,
            runnerVersion: body.runnerVersion,
            maxConcurrentJobs: body.maxConcurrentJobs,
            activeJobs: body.activeJobs,
            lastPollAt: seenAt
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
                reason: .poll,
                on: req.db,
                logger: req.logger
            )
        }
        return profileUpsert.profile?.capabilityProfile
    }

    /// Atomically finds and claims the best pending job for this runner.
    /// WorkerClaimQueue serializes concurrent calls at the application level;
    /// the inner transaction provides the DB-level guarantee for multi-process
    /// deployments where SQLite WAL serializes write transactions.
    private func claimNextEligibleJob(
        req: Request, body: WorkerActivityPayload, runnerProfile: RunnerCapabilityProfile?
    ) async throws -> ClaimedJob? {
        let evaluator = ClaimEvaluator(
            assignmentRequirements: req.application.assignmentRequirements,
            compatibilityMatcher: CompatibilityMatcher()
        )

        return try await req.application.workerClaimQueue.run {
            try await retrySQLiteBusyClaim {
                try await req.db.transaction { db -> ClaimedJob? in
                    let candidates = try await collectClaimCandidates(on: db)
                    return try await evaluateAndClaimCandidate(
                        candidates: candidates,
                        req: req,
                        body: body,
                        runnerProfile: runnerProfile,
                        evaluator: evaluator,
                        on: db
                    )
                }
            }
        }
    }

    /// Records "job assigned" diagnostics outside the claim transaction so
    /// `req.application` is safely accessible.
    private func recordJobAssignmentDiagnostics(
        req: Request, body: WorkerActivityPayload, claimed: ClaimedJob
    ) async {
        await req.application.diagnostics.recordJobAssigned(
            submission: claimed.submission, on: req.db, logger: req.logger
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
        let downloadVersion = await testSetupDownloadVersion(for: setup)
        guard
            let submissionURL = URL(string: "\(base)/api/v1/worker/submissions/\(submissionID)/download"),
            let testSetupURL = URL(
                string: "\(base)/api/v1/worker/testsetups/\(setupID)/download?v=\(downloadVersion)"
            )
        else {
            throw WorkerJobError.internalInconsistency(reason: "Failed to build worker download URLs from base=\(base)")
        }

        // Resolve per-student personalization inputs (issue #461) for this seed,
        // server-side, so the worker can bind them in generated scripts via
        // `_ck_inputs.py`. Shared with the browser seed endpoint via
        // `gradingInputs` so the two grading paths resolve identically. For a
        // pre-materialized validation submission we use the cached values
        // (no re-eval on this hot path); otherwise we resolve live.
        let personalizedInputs: [String: String]?
        if let materialization {
            personalizedInputs = materialization.inputs.isEmpty ? nil : materialization.inputs
        } else {
            let supportDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
            personalizedInputs = await PersonalizationSubstitution.gradingInputs(
                manifest: claimed.manifest, seedHex: assignmentSeed, supportFilesDirectory: supportDir)
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
            personalizedFiles: personalizedFiles
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
        let seenAt = Date()
        await req.application.workerActivityStore.markActive(
            workerID: body.workerID,
            hostname: body.hostname,
            runnerVersion: body.runnerVersion,
            maxConcurrentJobs: body.maxConcurrentJobs,
            activeJobs: body.activeJobs,
            lastHeartbeatAt: seenAt
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
                reason: .heartbeat,
                on: req.db,
                logger: req.logger
            )
        }
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

/// Loads the ordered list of claim candidates inside the claim transaction.
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
/// capability profile, and claims the first compatible one inside the
/// transaction.  When no candidate is claimable, emits a single
/// "no compatible runner available" diagnostic for the first blocked candidate
/// we saw and returns nil.
/// Bundles the per-claim collaborators that don't change between candidates,
/// so the per-candidate evaluation helper stays under the parameter-count cap.
private struct ClaimEvaluator {
    let assignmentRequirements: AssignmentRequirementService
    let compatibilityMatcher: CompatibilityMatcher
}

private func evaluateAndClaimCandidate(
    candidates: [(APISubmission, APITestSetup, TestProperties)],
    req: Request,
    body: WorkerActivityPayload,
    runnerProfile: RunnerCapabilityProfile?,
    evaluator: ClaimEvaluator,
    on db: Database
) async throws -> ClaimedJob? {
    var blockedCandidate: BlockedCandidate?

    for (submission, setup, manifest) in candidates {
        let loadedRequirements = try await evaluator.assignmentRequirements.loadRequirement(
            for: submission, on: db)
        let requirementSpec = loadedRequirements.requirement?.requirementSpec

        req.application.diagnostics.recordAssignmentRequirementsLoaded(
            submission: submission,
            assignmentID: loadedRequirements.assignmentID,
            requirements: requirementSpec,
            logger: req.logger
        )

        let compatibilityResult = evaluator.compatibilityMatcher.evaluate(
            runnerProfile: runnerProfile,
            requirements: requirementSpec
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

        // Claim inside the transaction — atomic with the select above.
        submission.setStatus(.assigned)
        submission.workerID = body.workerID
        submission.assignedAt = Date()
        try await submission.save(on: db)

        return ClaimedJob(
            submission: submission,
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

    private struct Key: Hashable {
        let manifest: String
        let zipPath: String
        let zipSize: UInt64
        let zipModified: Date
    }

    private var entries: [String: (key: Key, version: String)] = [:]

    func version(for setup: APITestSetup) -> String {
        let setupID = setup.id ?? setup.zipPath
        let attributes = try? FileManager.default.attributesOfItem(atPath: setup.zipPath)
        let key = Key(
            manifest: setup.manifest,
            zipPath: setup.zipPath,
            zipSize: (attributes?[.size] as? UInt64) ?? 0,
            zipModified: (attributes?[.modificationDate] as? Date) ?? .distantPast)

        if let cached = entries[setupID], cached.key == key { return cached.version }

        var material = Data(setup.manifest.utf8)
        if let zipData = try? Data(contentsOf: URL(fileURLWithPath: setup.zipPath)) {
            material.append(Data("|zip=".utf8))
            material.append(zipData)
        }
        let version = String(sha256HexDigest(material).prefix(16))
        entries[setupID] = (key, version)
        return version
    }
}

private func testSetupDownloadVersion(for setup: APITestSetup) async -> String {
    await TestSetupDownloadVersionCache.shared.version(for: setup)
}

// MARK: - Application-level claim serializer

/// Ensures at most one worker-job claim operation executes at a time.
/// This complements the DB transaction: SQLite WAL serializes write
/// transactions in file-based deployments; this queue does the same for
/// in-process scenarios (single-node servers, test environments).
///
/// Implemented as a Swift actor — actor isolation replaces the previous
/// NSLock + @unchecked Sendable approach, giving compile-time concurrency
/// safety with no manual lock discipline.
actor WorkerClaimQueue {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var active = false

    func run<T>(_ work: () async throws -> T) async throws -> T {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if active { waiting.append(c) } else { active = true; c.resume() }
        }
        defer { advance() }
        return try await work()
    }

    private func advance() {
        if waiting.isEmpty { active = false } else { waiting.removeFirst().resume() }
    }
}

private func retrySQLiteBusyClaim<T>(
    maxAttempts: Int = 3,
    retryDelayNanoseconds: UInt64 = 20_000_000,
    work: @escaping () async throws -> T
) async throws -> T {
    precondition(maxAttempts > 0, "maxAttempts must be positive")

    var attempt = 1
    while true {
        do {
            return try await work()
        } catch {
            guard attempt < maxAttempts, isSQLiteBusyError(error) else {
                throw error
            }
            attempt += 1
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }
}

private func isSQLiteBusyError(_ error: Error) -> Bool {
    if let sqliteError = error as? SQLiteError {
        switch sqliteError.reason {
        case .busy, .busyInRecovery, .busyInSnapshot, .busyTimeout:
            return true
        default:
            break
        }
    }

    return error.localizedDescription.localizedCaseInsensitiveContains("database is locked")
}

struct WorkerClaimQueueKey: StorageKey {
    typealias Value = WorkerClaimQueue
}

extension Application {
    var workerClaimQueue: WorkerClaimQueue {
        if let q = storage[WorkerClaimQueueKey.self] { return q }
        let q = WorkerClaimQueue()
        storage[WorkerClaimQueueKey.self] = q
        return q
    }
}

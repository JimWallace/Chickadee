import Vapor
import Fluent
import Core
import Foundation
import FluentSQLiteDriver
import Crypto

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
        let hostname = body.hostname
        let seenAt = Date()

        // Reject a runner whose workerID is already claimed by a different host
        // within the activity TTL (3× the runner's max backoff of 30 s = 90 s).
        // Same hostname is treated as a restart of the same process, not a conflict.
        let conflictTTL: TimeInterval = 90
        if await req.application.workerActivityStore.isConflict(
            workerID: body.workerID,
            hostname: hostname,
            ttlSeconds: conflictTTL
        ) {
            struct ConflictBody: Content { let error: String }
            let msg = "workerID \"\(body.workerID)\" is already in use by an active runner. " +
                      "Choose a different --worker-id or wait for the existing runner to time out."
            return try Response(
                status: .conflict,
                headers: ["Content-Type": "application/json"],
                body: .init(data: JSONEncoder().encode(ConflictBody(error: msg)))
            )
        }

        await req.application.workerActivityStore.markActive(
            workerID: body.workerID,
            hostname: hostname,
            runnerVersion: body.runnerVersion,
            maxConcurrentJobs: body.maxConcurrentJobs,
            activeJobs: body.activeJobs,
            lastPollAt: seenAt
        )
        let profileUpsert = try await req.application.runnerProfiles.registerOrUpdate(
            runnerID: body.workerID,
            displayName: hostname,
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

        // Atomically find and claim the best pending job.
        // WorkerClaimQueue serializes concurrent calls at the application level;
        // the inner transaction provides the DB-level guarantee for multi-process
        // deployments where SQLite WAL serializes write transactions.
        let compatibilityMatcher = CompatibilityMatcher()
        let assignmentRequirements = req.application.assignmentRequirements
        let runnerProfile = profileUpsert.profile?.capabilityProfile

        typealias ClaimedJob = (
            submission: APISubmission,
            setup: APITestSetup,
            manifest: TestProperties,
            assignmentID: UUID?,
            requirementSpec: AssignmentRequirementSpec?
        )
        let claimed: ClaimedJob? = try await req.application.workerClaimQueue.run {
        try await retrySQLiteBusyClaim {
        try await req.db.transaction { db -> ClaimedJob? in
            let studentSubmissions = try await APISubmission.query(on: db)
                .filter(\.$status == "pending")
                .filter(\.$kind == APISubmission.Kind.student)
                .sort(\.$submittedAt, .ascending)
                .all()

            var candidates: [(APISubmission, APITestSetup, TestProperties)] = []
            for candidate in studentSubmissions {
                guard let setup = try await APITestSetup.find(candidate.testSetupID, on: db) else { continue }
                let data = Data(setup.manifest.utf8)
                guard let manifest = try? JSONDecoder().decode(TestProperties.self, from: data) else { continue }
                // Accept both worker-mode and browser-mode pending submissions.
                // Browser-mode submissions only become pending when the client-side
                // runner fails or times out; the worker serves as a backstop that
                // runs the .py test scripts natively via python3.
                candidates.append((candidate, setup, manifest))
            }

            // Validation submissions are always worker-mode (instructors validate via worker).
            let pendingValidation = try await APISubmission.query(on: db)
                .filter(\.$status == "pending")
                .filter(\.$kind == APISubmission.Kind.validation)
                .sort(\.$submittedAt, .ascending)
                .all()

            for validation in pendingValidation {
                guard let valSetup = try await APITestSetup.find(validation.testSetupID, on: db) else {
                    throw WorkerJobError.testSetupNotFound(id: validation.testSetupID)
                }
                let valManifestData = Data(valSetup.manifest.utf8)
                let valManifest     = try JSONDecoder().decode(TestProperties.self, from: valManifestData)
                candidates.append((validation, valSetup, valManifest))
            }

            var blockedCandidate: (
                submission: APISubmission,
                assignmentID: UUID?,
                requirements: AssignmentRequirementSpec?,
                result: CompatibilityResult
            )?

            for (submission, setup, manifest) in candidates {
                let loadedRequirements = try await assignmentRequirements.loadRequirement(for: submission, on: db)
                let requirementSpec = loadedRequirements.requirement?.requirementSpec

                req.application.diagnostics.recordAssignmentRequirementsLoaded(
                    submission: submission,
                    assignmentID: loadedRequirements.assignmentID,
                    requirements: requirementSpec,
                    logger: req.logger
                )

                let compatibilityResult = compatibilityMatcher.evaluate(
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
                        blockedCandidate = (
                            submission: submission,
                            assignmentID: loadedRequirements.assignmentID,
                            requirements: requirementSpec,
                            result: compatibilityResult
                        )
                    }
                    continue
                }

                // Claim inside the transaction — atomic with the select above.
                submission.status = "assigned"
                submission.workerID = body.workerID
                submission.assignedAt = Date()
                try await submission.save(on: db)

                return (
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
        } // end transaction
        } // end retrySQLiteBusyClaim
        } // end workerClaimQueue.run

        guard let (submission, setup, manifest, assignmentID, requirementSpec) = claimed else {
            return Response(status: .noContent)
        }

        await req.application.workerActivityStore.incrementAssignedJobs(for: body.workerID)

        // Record diagnostics outside the transaction so req.application is safely accessible.
        await req.application.diagnostics.recordJobAssigned(
            submission: submission, on: req.db, logger: req.logger
        )
        req.application.diagnostics.recordCompatibleJobAssignment(
            submission: submission,
            assignmentID: assignmentID,
            runnerID: body.workerID,
            requirements: requirementSpec,
            logger: req.logger
        )

        let base = resolvedWorkerBaseURL(req: req)

        let setupDownloadVersion = testSetupDownloadVersion(for: setup)
        let job = Job(
            submissionID:       submission.id!,
            testSetupID:        setup.id!,
            attemptNumber:      submission.attemptNumber ?? 1,
            submissionURL:      URL(string: "\(base)/api/v1/worker/submissions/\(submission.id!)/download")!,
            testSetupURL:       URL(string: "\(base)/api/v1/worker/testsetups/\(setup.id!)/download?v=\(setupDownloadVersion)")!,
            manifest:           manifest,
            submissionFilename: submission.filename
        )

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

private func resolvedWorkerBaseURL(req: Request) -> String {
    if let explicit = Environment.get("WORKER_PUBLIC_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !explicit.isEmpty {
        return explicit.hasSuffix("/") ? String(explicit.dropLast()) : explicit
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
    let port     = req.application.http.server.configuration.port
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

private func testSetupDownloadVersion(for setup: APITestSetup) -> String {
    var material = Data(setup.manifest.utf8)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: setup.zipPath) {
        if let modified = attrs[.modificationDate] as? Date {
            material.append(Data("|mtime=\(modified.timeIntervalSince1970)".utf8))
        }
        if let size = attrs[.size] {
            material.append(Data("|size=\(size)".utf8))
        }
    }
    let digest = Data(SHA256.hash(data: material)).map { String(format: "%02x", $0) }.joined()
    return String(digest.prefix(16))
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

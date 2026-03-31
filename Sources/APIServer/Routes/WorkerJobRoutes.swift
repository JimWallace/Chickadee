import Vapor
import Fluent
import Core
import Foundation

struct WorkerJobRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "v1", "worker")
            .post("request", use: requestJob)
    }

    // MARK: - POST /api/v1/worker/request

    @Sendable
    func requestJob(req: Request) async throws -> Response {
        let body     = try req.content.decode(WorkerRequestBody.self)
        let hostname = body.hostname ?? ""

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

        await req.application.workerActivityStore.markActive(workerID: body.workerID, hostname: hostname)

        // Atomically find and claim the best pending job.
        // WorkerClaimQueue serializes concurrent calls at the application level;
        // the inner transaction provides the DB-level guarantee for multi-process
        // deployments where SQLite WAL serializes write transactions.
        typealias ClaimedJob = (submission: APISubmission, setup: APITestSetup, manifest: TestProperties)
        let claimed: ClaimedJob? = try await req.application.workerClaimQueue.run {
        try await req.db.transaction { db -> ClaimedJob? in
            // Find the oldest pending student submission backed by a worker-mode test setup.
            // Submissions for browser-mode test setups (gradingMode == .browser) are
            // handled by the client-side WASM runner and must not be claimed here.
            let studentCandidates = try await APISubmission.query(on: db)
                .filter(\.$status == "pending")
                .filter(\.$kind == APISubmission.Kind.student)
                .sort(\.$submittedAt, .ascending)
                .all()

            var workerModeStudent: (APISubmission, APITestSetup, TestProperties)?
            for candidate in studentCandidates {
                guard let setup = try await APITestSetup.find(candidate.testSetupID, on: db) else { continue }
                let data = Data(setup.manifest.utf8)
                guard
                    let manifest = try? JSONDecoder().decode(TestProperties.self, from: data),
                    manifest.gradingMode == .worker
                else { continue }
                workerModeStudent = (candidate, setup, manifest)
                break
            }

            // Validation submissions are always worker-mode (instructors validate via worker).
            let pendingValidation = try await APISubmission.query(on: db)
                .filter(\.$status == "pending")
                .filter(\.$kind == APISubmission.Kind.validation)
                .sort(\.$submittedAt, .ascending)
                .first()

            // Prefer student submissions, fall back to validation.
            let submission: APISubmission
            let setup: APITestSetup
            let manifest: TestProperties

            if let wm = workerModeStudent {
                (submission, setup, manifest) = wm
            } else if let val = pendingValidation {
                guard let valSetup = try await APITestSetup.find(val.testSetupID, on: db) else {
                    throw WorkerJobError.testSetupNotFound(id: val.testSetupID)
                }
                let valManifestData = Data(valSetup.manifest.utf8)
                let valManifest     = try JSONDecoder().decode(TestProperties.self, from: valManifestData)
                (submission, setup, manifest) = (val, valSetup, valManifest)
            } else {
                return nil
            }

            // Claim inside the transaction — atomic with the select above.
            submission.status     = "assigned"
            submission.workerID   = body.workerID
            submission.assignedAt = Date()
            try await submission.save(on: db)

            return (submission, setup, manifest)
        } // end transaction
        } // end workerClaimQueue.run

        guard let (submission, setup, manifest) = claimed else {
            return Response(status: .noContent)
        }

        let base = resolvedWorkerBaseURL(req: req)

        let job = Job(
            submissionID:       submission.id!,
            testSetupID:        setup.id!,
            attemptNumber:      submission.attemptNumber ?? 1,
            submissionURL:      URL(string: "\(base)/api/v1/worker/submissions/\(submission.id!)/download")!,
            testSetupURL:       URL(string: "\(base)/api/v1/worker/testsetups/\(setup.id!)/download")!,
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
}

struct WorkerRequestBody: Content {
    let workerID: String
    let hostname: String?
    let runnerVersion: String?
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

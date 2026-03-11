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
        try await requireWorkerSecret(req)

        let body = try req.content.decode(WorkerRequestBody.self)
        await req.application.workerActivityStore.markActive(workerID: body.workerID)

        // Find the oldest pending student submission backed by a worker-mode test setup.
        // Submissions for browser-mode test setups (gradingMode == .browser) are
        // handled by the client-side WASM runner and must not be claimed here.
        let studentCandidates = try await APISubmission.query(on: req.db)
            .filter(\.$status == "pending")
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .ascending)
            .all()

        var workerModeStudent: (submission: APISubmission, setup: APITestSetup, manifest: TestProperties)?
        for candidate in studentCandidates {
            guard let setup = try await APITestSetup.find(candidate.testSetupID, on: req.db) else { continue }
            let data = Data(setup.manifest.utf8)
            guard
                let manifest = try? JSONDecoder().decode(TestProperties.self, from: data),
                manifest.gradingMode == .worker
            else { continue }
            workerModeStudent = (candidate, setup, manifest)
            break
        }

        // Validation submissions are always worker-mode (instructors validate via worker).
        let pendingValidation = try await APISubmission.query(on: req.db)
            .filter(\.$status == "pending")
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .ascending)
            .first()

        // Prefer student submissions, fall back to validation.
        let submission: APISubmission
        let setup: APITestSetup
        let manifest: TestProperties

        if let wm = workerModeStudent {
            submission = wm.submission
            setup      = wm.setup
            manifest   = wm.manifest
        } else if let val = pendingValidation {
            submission = val
            guard let valSetup = try await APITestSetup.find(submission.testSetupID, on: req.db) else {
                throw Abort(.internalServerError, reason: "TestSetup \(submission.testSetupID) not found")
            }
            let valManifestData = Data(valSetup.manifest.utf8)
            let valManifest     = try JSONDecoder().decode(TestProperties.self, from: valManifestData)
            setup    = valSetup
            manifest = valManifest
        } else {
            return Response(status: .noContent)
        }

        // Atomically claim the submission for this worker.
        submission.status     = "assigned"
        submission.workerID   = body.workerID
        submission.assignedAt = Date()
        try await submission.save(on: req.db)

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

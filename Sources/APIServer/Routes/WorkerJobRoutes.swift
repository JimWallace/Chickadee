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

        guard
            let submission = try await APISubmission.query(on: req.db)
                .filter(\.$status == "pending")
                .sort(\.$submittedAt, .ascending)
                .first()
        else {
            return Response(status: .noContent)
        }

        submission.status     = "assigned"
        submission.workerID   = body.workerID
        submission.assignedAt = Date()
        try await submission.save(on: req.db)

        guard let setup = try await APITestSetup.find(submission.testSetupID, on: req.db) else {
            throw Abort(.internalServerError, reason: "TestSetup \(submission.testSetupID) not found")
        }

        let manifestData = Data(setup.manifest.utf8)
        let decoder      = JSONDecoder()
        let manifest     = try decoder.decode(TestProperties.self, from: manifestData)

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

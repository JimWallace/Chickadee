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

        let baseURL = req.application.http.server.configuration.hostname
        let port    = req.application.http.server.configuration.port
        let base    = "http://\(baseURL):\(port)"

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

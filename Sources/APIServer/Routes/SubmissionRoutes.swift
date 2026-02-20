// APIServer/Routes/SubmissionRoutes.swift

import Vapor
import Fluent
import Core
import Foundation

struct SubmissionRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")

        // POST /api/v1/worker/request
        api.grouped("worker").post("request", use: requestJob)

        // POST /api/v1/submissions
        api.post("submissions", use: createSubmission)
    }

    // MARK: - POST /api/v1/worker/request

    @Sendable
    func requestJob(req: Request) async throws -> Response {
        let body = try req.content.decode(WorkerRequestBody.self)

        // Find the oldest pending submission.
        guard
            let submission = try await APISubmission.query(on: req.db)
                .filter(\.$status == "pending")
                .sort(\.$submittedAt, .ascending)
                .first()
        else {
            return Response(status: .noContent)
        }

        // Claim it atomically.
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
            submissionID:  submission.id!,
            testSetupID:   setup.id!,
            attemptNumber: submission.attemptNumber ?? 1,
            submissionURL: URL(string: "\(base)/api/v1/submissions/\(submission.id!)/download")!,
            testSetupURL:  URL(string: "\(base)/api/v1/testsetups/\(setup.id!)/download")!,
            manifest:      manifest
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

    // MARK: - POST /api/v1/submissions

    @Sendable
    func createSubmission(req: Request) async throws -> SubmissionCreatedResponse {
        let body = try req.content.decode(CreateSubmissionBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        let submissionsDir = req.application.submissionsDirectory
        let subID          = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath        = submissionsDir + "\(subID).zip"

        guard let zipData = body.zipBase64.data(using: .utf8),
              let decoded = Data(base64Encoded: zipData)
        else {
            throw Abort(.badRequest, reason: "zipBase64 is not valid base-64")
        }
        try decoded.write(to: URL(fileURLWithPath: zipPath))

        // Count prior submissions for this test setup to determine attempt number.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setup.id!)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setup.id!,
            zipPath:       zipPath,
            attemptNumber: priorCount + 1
        )
        try await submission.save(on: req.db)

        return SubmissionCreatedResponse(submissionID: subID)
    }
}

// MARK: - GET /api/v1/submissions/:id/download

struct SubmissionDownloadRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "v1", "submissions", ":submissionID")
            .get("download", use: download)
    }

    @Sendable
    func download(req: Request) async throws -> Response {
        guard let subID = req.parameters.get("submissionID"),
              let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
    }
}

// MARK: - Request / Response types

struct WorkerRequestBody: Content {
    let workerID: String
    let hostname: String?
}

struct CreateSubmissionBody: Content {
    let testSetupID: String
    let zipBase64: String
}

struct SubmissionCreatedResponse: Content {
    let submissionID: String
}

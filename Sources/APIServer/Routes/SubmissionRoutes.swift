// APIServer/Routes/SubmissionRoutes.swift
//
// Phase 2: job-request endpoint.
// Workers POST here to claim the next pending submission that matches
// their supported languages.  Returns a Job (200) or 204 if nothing
// is pending.

import Vapor
import Fluent
import Core
import Foundation

struct SubmissionRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")

        // POST /api/v1/worker/request
        api.grouped("worker").post("request", use: requestJob)

        // POST /api/v1/submissions  (instructor / client submits work)
        api.post("submissions", use: createSubmission)
    }

    // MARK: - POST /api/v1/worker/request

    @Sendable
    func requestJob(req: Request) async throws -> Response {
        let body = try req.content.decode(WorkerRequestBody.self)

        // Find the oldest pending submission whose language the worker supports.
        guard
            let submission = try await APISubmission.query(on: req.db)
                .filter(\.$status == "pending")
                .filter(\.$language ~~ body.supportedLanguages)
                .sort(\.$submittedAt, .ascending)
                .first()
        else {
            return Response(status: .noContent)
        }

        // Claim it atomically: mark as assigned.
        submission.status     = "assigned"
        submission.workerID   = body.workerID
        submission.assignedAt = Date()
        try await submission.save(on: req.db)

        // Fetch the matching test setup so we can embed the manifest.
        guard let setup = try await APITestSetup.find(submission.testSetupID, on: req.db) else {
            throw Abort(.internalServerError, reason: "TestSetup \(submission.testSetupID) not found")
        }

        let manifestData = Data(setup.manifest.utf8)
        let decoder      = JSONDecoder()
        let manifest     = try decoder.decode(TestSetupManifest.self, from: manifestData)

        let baseURL = req.application.http.server.configuration.hostname
        let port    = req.application.http.server.configuration.port
        let base    = "http://\(baseURL):\(port)"

        let job = Job(
            submissionID:  submission.id!,
            testSetupID:   setup.id!,
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

        // Validate the referenced test setup exists.
        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        // Save the zip.
        let submissionsDir = req.application.submissionsDirectory
        let subID          = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath        = submissionsDir + "\(subID).zip"

        guard let zipData = body.zipBase64.data(using: .utf8),
              let decoded = Data(base64Encoded: zipData)
        else {
            throw Abort(.badRequest, reason: "zipBase64 is not valid base-64")
        }
        try decoded.write(to: URL(fileURLWithPath: zipPath))

        let submission = APISubmission(
            id:          subID,
            testSetupID: setup.id!,
            language:    setup.language,
            zipPath:     zipPath
        )
        try await submission.save(on: req.db)

        return SubmissionCreatedResponse(submissionID: subID)
    }
}

// MARK: - GET /api/v1/submissions/:id/download  (download submission zip)

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
        return req.fileio.streamFile(at: submission.zipPath)
    }
}

// MARK: - Request / Response types

struct WorkerRequestBody: Content {
    let workerID: String
    let supportedLanguages: [String]
    let hostname: String?
}

struct CreateSubmissionBody: Content {
    let testSetupID: String
    let zipBase64: String       // base-64 encoded zip contents
}

struct SubmissionCreatedResponse: Content {
    let submissionID: String
}

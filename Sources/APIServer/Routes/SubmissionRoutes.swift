// APIServer/Routes/SubmissionRoutes.swift

import Vapor
import Fluent
import Core
import Foundation

struct SubmissionRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")

        // POST /api/v1/submissions
        api.post("submissions", use: createSubmission)

        // POST /api/v1/submissions/file  — multipart, accepts raw .ipynb / .py
        api.post("submissions", "file", use: createSubmissionFile)
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

    // MARK: - POST /api/v1/submissions/file

    @Sendable
    func createSubmissionFile(req: Request) async throws -> SubmissionCreatedResponse {
        let body = try req.content.decode(SubmitFileBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        let submissionsDir = req.application.submissionsDirectory
        let subID          = "sub_\(UUID().uuidString.lowercased().prefix(8))"

        // Derive extension from the provided filename, default to original ext.
        let ext      = URL(fileURLWithPath: body.filename).pathExtension
        let filePath = submissionsDir + "\(subID).\(ext.isEmpty ? "bin" : ext)"

        // For .ipynb submissions, merge the instructor's hidden test cells back in
        // before saving, so the worker grades with the full authoritative test suite.
        let fileData: Data
        if body.filename.hasSuffix(".ipynb"),
           let setup2 = try await APITestSetup.find(body.testSetupID, on: req.db),
           let instructorData = try? notebookData(for: setup2) {
            fileData = mergeNotebook(student: body.file, instructor: instructorData)
        } else {
            fileData = body.file   // .py or other files — no merge needed
        }
        try fileData.write(to: URL(fileURLWithPath: filePath))

        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setup.id!)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setup.id!,
            zipPath:       filePath,
            attemptNumber: priorCount + 1,
            filename:      body.filename
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
        let caller = try req.auth.require(APIUser.self)
        guard let subID = req.parameters.get("submissionID"),
              let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        if !caller.isInstructor && submission.userID != caller.id {
            throw Abort(.forbidden)
        }
        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
    }
}

// MARK: - Request / Response types

struct CreateSubmissionBody: Content {
    let testSetupID: String
    let zipBase64: String
}

struct SubmitFileBody: Content {
    var testSetupID: String
    var filename: String
    var file: Data
}

struct SubmissionCreatedResponse: Content {
    let submissionID: String
}

// APIServer/Routes/SubmissionRoutes.swift

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

struct SubmissionRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")

        // POST /api/v1/submissions
        api.post("submissions", use: createSubmission)

        // POST /api/v1/submissions/file  — multipart, accepts raw .ipynb / .py
        api.post("submissions", "file", use: createSubmissionFile)
    }

    // MARK: - POST /api/v1/submissions

    @Sendable
    func createSubmission(req: Request) async throws -> SubmissionCreatedResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try await req.decodeContent(CreateSubmissionBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }
        // Scope intake to the setup's own course: the caller must be enrolled in
        // the course that owns the setup, so a submission can't be enqueued
        // against another course's setup by ID (#417 Slice D).
        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        guard let zipData = body.zipBase64.data(using: .utf8),
            let decoded = Data(base64Encoded: zipData)
        else {
            throw AppError.invalidParameter(name: "zipBase64", reason: "not valid base-64")
        }

        // This route group is course staff only (`ActiveCourseStaffMiddleware`
        // in routes.swift). The row has no owner, so it is no student's
        // attempt: its attempt number is counted per setup and it awards no
        // Pathfinder. No deadline gate runs, because staff are never gated.
        let intake = SubmissionIntake(req: req)
        let subID = intake.submissionID
        try await intake.accept(
            setup: setup, owner: nil,
            artifact: .bytes(decoded, fileExtension: "zip"),
            filename: nil, status: .pending)

        return SubmissionCreatedResponse(submissionID: subID)
    }

    // MARK: - POST /api/v1/submissions/file

    @Sendable
    func createSubmissionFile(req: Request) async throws -> SubmissionCreatedResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try await req.decodeContent(SubmitFileBody.self)
        let submittedFilename = submissionFilenameForStorage(
            uploadedName: body.filename,
            fallback: "submission.bin"
        )

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }
        // Scope intake to the setup's own course (see createSubmission) (#417 Slice D).
        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        let intake = SubmissionIntake(req: req)
        let subID = intake.submissionID

        // For .ipynb submissions, merge the instructor's hidden test cells back in
        // before saving, so the worker grades with the full authoritative test suite.
        let fileData =
            submittedFilename.hasSuffix(".ipynb")
            ? try await intake.mergedWithInstructorNotebook(body.file, setup: setup)
            : body.file  // .py or other files — no merge needed

        // Derive the stored extension from the provided filename. No owner and
        // no deadline gate, as in createSubmission.
        let ext = URL(fileURLWithPath: submittedFilename).pathExtension
        try await intake.accept(
            setup: setup, owner: nil,
            artifact: .bytes(fileData, fileExtension: ext.isEmpty ? "bin" : ext),
            filename: submittedFilename, status: .pending)

        return SubmissionCreatedResponse(submissionID: subID)
    }
}

// MARK: - GET /api/v1/submissions/:id/download

struct SubmissionDownloadRoute: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api", "v1", "submissions", ":submissionID")
            .get("download", use: download)
    }

    @Sendable
    func download(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw AppError.notFound(resource: "Submission")
        }
        // Course staff (TA+ or admin) may download any submission in their
        // course; everyone else only their own (#417 Slice G).
        let isStaff = try await isSubmissionStaff(caller, submission: submission, on: req.db)
        if !isStaff && submission.userID != caller.id {
            throw AppError.forbidden(action: "download this submission")
        }
        let downloadName =
            submission.filename
            ?? URL(fileURLWithPath: submission.zipPath).lastPathComponent
        // Stream from disk (#1158): the old Data(contentsOf:) buffered the
        // whole artifact per request — the sibling test-setup download has
        // streamed for a long time.
        let response = try await req.fileio.asyncStreamFile(at: submission.zipPath)
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(downloadName)\"")
        return response
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

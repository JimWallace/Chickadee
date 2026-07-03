// APIServer/Routes/SubmissionRoutes.swift

import Core
import Fluent
import Foundation
import Vapor

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
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(CreateSubmissionBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }
        // Scope intake to the setup's own course: the caller must be enrolled in
        // the course that owns the setup, so a submission can't be enqueued
        // against another course's setup by ID (#417 Slice D).
        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        let submissionsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = submissionsDir + "\(subID).zip"

        guard let zipData = body.zipBase64.data(using: .utf8),
            let decoded = Data(base64Encoded: zipData)
        else {
            throw AppError.invalidParameter(name: "zipBase64", reason: "not valid base-64")
        }
        // Offload the disk write to the NIO thread pool so a deadline-spike of
        // concurrent submissions doesn't serialize on synchronous file I/O.
        try await req.fileio.writeFile(.init(data: decoded), at: zipPath)

        // Attempt number for API submissions stays per-setup (no user identity
        // on this path), assigned race-free inside one transaction.
        let submission = APISubmission(
            id: subID,
            testSetupID: body.testSetupID,
            zipPath: zipPath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: nil, on: req.db)
        await req.application.diagnostics.recordSubmissionCreated(
            submission: submission,
            on: req.db,
            logger: req.logger
        )
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

        return SubmissionCreatedResponse(submissionID: subID)
    }

    // MARK: - POST /api/v1/submissions/file

    @Sendable
    func createSubmissionFile(req: Request) async throws -> SubmissionCreatedResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(SubmitFileBody.self)
        let submittedFilename = submissionFilenameForStorage(
            uploadedName: body.filename,
            fallback: "submission.bin"
        )

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw AppError.invalidParameter(name: "testSetupID", reason: "no test setup with that ID")
        }
        // Scope intake to the setup's own course (see createSubmission) (#417 Slice D).
        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        let submissionsDir = req.application.submissionsDirectory
        let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"

        // Derive extension from the provided filename, default to original ext.
        let ext = URL(fileURLWithPath: submittedFilename).pathExtension
        let filePath = submissionsDir + "\(subID).\(ext.isEmpty ? "bin" : ext)"

        // For .ipynb submissions, merge the instructor's hidden test cells back in
        // before saving, so the worker grades with the full authoritative test suite.
        let fileData: Data
        if submittedFilename.hasSuffix(".ipynb") {
            // The instructor-notebook disk read and the JSON merge are both
            // blocking work; run them on the NIO thread pool so a deadline-spike
            // of concurrent .ipynb submissions doesn't serialize on the
            // cooperative executor.
            let source = NotebookSourceRef(setup)
            let studentBytes = body.file
            fileData = try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
                guard let instructorData = try? notebookData(from: source) else {
                    return studentBytes  // no instructor notebook → submit as-is
                }
                return mergeNotebook(student: studentBytes, instructor: instructorData)
            }.get()
        } else {
            fileData = body.file  // .py or other files — no merge needed
        }
        // Offload the disk write to the NIO thread pool (see createSubmission).
        try await req.fileio.writeFile(.init(data: fileData), at: filePath)

        let submission = APISubmission(
            id: subID,
            testSetupID: body.testSetupID,
            zipPath: filePath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            filename: submittedFilename,
            kind: APISubmission.Kind.student
        )
        try await saveSubmissionWithNextAttemptNumber(submission, userID: nil, on: req.db)
        await req.application.diagnostics.recordSubmissionCreated(
            submission: submission,
            on: req.db,
            logger: req.logger
        )
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

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
        // Course staff (TA+ or admin) may download any submission in their
        // course; everyone else only their own (#417 Slice G).
        let isStaff = try await isSubmissionStaff(caller, submission: submission, on: req.db)
        if !isStaff && submission.userID != caller.id {
            throw Abort(.forbidden)
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

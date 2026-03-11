// APIServer/Routes/BrowserResultRoutes.swift
//
// Accepts grading results from the student's browser (Pyodide run).
// The browser runner runs tests locally and submits the notebook + results
// in one atomic call — no native worker re-run is queued.
//
//   POST /api/v1/submissions/browser-result
//
// Multipart body:
//   collection  — JSON text of a TestOutcomeCollection
//   notebook    — raw bytes of the student's .ipynb file
//   testSetupID — ID of the test setup this submission targets

import Vapor
import Fluent
import Core
import Foundation

struct BrowserResultRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let submissions = routes.grouped("api", "v1", "submissions")
        submissions.post("browser-result", use: submitBrowserResult)
        submissions.post("runner-submit", use: submitRunnerSubmission)
    }

    // MARK: - POST /api/v1/submissions/browser-result

    @Sendable
    func submitBrowserResult(req: Request) async throws -> BrowserResultResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(BrowserResultBody.self)

        // Validate the referenced test setup exists.
        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        // Decode the TestOutcomeCollection the browser sent.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection: TestOutcomeCollection
        do {
            guard let data = body.collection.data(using: .utf8) else {
                throw Abort(.badRequest, reason: "collection is not valid UTF-8")
            }
            collection = try decoder.decode(TestOutcomeCollection.self, from: data)
        } catch let e as DecodingError {
            throw Abort(.unprocessableEntity, reason: "Invalid TestOutcomeCollection: \(e)")
        }

        // Persist the notebook to disk as the submission artifact.
        // Merge the student's notebook with the instructor's canonical notebook
        // so that hidden test cells (secret, release) are re-injected before
        // the worker runs the full authoritative test suite.
        let subsDir        = req.application.submissionsDirectory
        let subID          = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let nbPath         = subsDir + "\(subID).ipynb"
        let instructorData = (try? notebookData(for: setup)) ?? body.notebook
        let notebookToSave = mergeNotebook(student: body.notebook, instructor: instructorData)
        try notebookToSave.write(to: URL(fileURLWithPath: nbPath))

        // Count prior submissions to derive the attempt number.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setup.id!)
            .filter(\.$userID == caller.id)
            .filter(\.$kind == APISubmission.Kind.student)
            .count()
        let attemptNumber = priorCount + 1

        // Create a submission record in "browser-complete" status.
        // Browser results are authoritative — no native worker re-run is queued.
        let submission = APISubmission(
            id:            subID,
            testSetupID:   setup.id!,
            zipPath:       nbPath,
            attemptNumber: attemptNumber,
            status:        "browser-complete",
            filename:      "\(subID).ipynb",
            userID:        caller.id,
            kind:          APISubmission.Kind.student
        )
        try await submission.save(on: req.db)

        // Persist the browser result, tagged source="browser".
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let collectionJSON = try String(data: encoder.encode(collection), encoding: .utf8) ?? "{}"

        let browserResult = APIResult(
            id:             "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID:   subID,
            collectionJSON: collectionJSON,
            source:         "browser"
        )
        try await browserResult.save(on: req.db)

        req.logger.info("Browser result stored for \(subID)")

        return BrowserResultResponse(submissionID: subID)
    }

    // MARK: - POST /api/v1/submissions/runner-submit

    @Sendable
    func submitRunnerSubmission(req: Request) async throws -> RunnerSubmissionResponse {
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(RunnerSubmitBody.self)

        guard let setup = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
        }

        let subsDir = req.application.submissionsDirectory
        let subID   = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let nbPath  = subsDir + "\(subID).ipynb"

        // Always merge with canonical instructor notebook so hidden tests are present.
        let instructorData = (try? notebookData(for: setup)) ?? body.notebook
        let notebookToSave = mergeNotebook(student: body.notebook, instructor: instructorData)
        try notebookToSave.write(to: URL(fileURLWithPath: nbPath))

        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setup.id!)
            .filter(\.$userID == caller.id)
            .filter(\.$kind == APISubmission.Kind.student)
            .count()

        let submittedFilename = normalizedNotebookFilename(body.filename)
        let submission = APISubmission(
            id:            subID,
            testSetupID:   setup.id!,
            zipPath:       nbPath,
            attemptNumber: priorCount + 1,
            status:        "pending",
            filename:      submittedFilename,
            userID:        caller.id,
            kind:          APISubmission.Kind.student
        )
        try await submission.save(on: req.db)

        // For browser-mode test setups the client-side WASM runner picks up the job;
        // waking the local native runner would waste resources and claim nothing
        // (WorkerJobRoutes filters out browser-mode submissions).
        let manifestData = Data(setup.manifest.utf8)
        let isWorkerMode = (try? JSONDecoder().decode(TestProperties.self, from: manifestData))
            .map { $0.gradingMode == .worker } ?? true
        if isWorkerMode {
            await ensureLocalRunnerForSubmissionIfNeeded(req: req)
        }

        return RunnerSubmissionResponse(submissionID: subID)
    }
}

// MARK: - Request / Response types

struct BrowserResultBody: Content {
    /// JSON-encoded TestOutcomeCollection from Pyodide.
    var collection: String
    /// Raw bytes of the student's .ipynb file.
    var notebook: Data
    /// The test setup this submission belongs to.
    var testSetupID: String
}

struct RunnerSubmitBody: Content {
    var notebook: Data
    var testSetupID: String
    var filename: String?
}

struct BrowserResultResponse: Content {
    /// ID of the submission record (status: browser-complete).
    let submissionID: String
}

struct RunnerSubmissionResponse: Content {
    let submissionID: String
}

private func normalizedNotebookFilename(_ filename: String?) -> String {
    guard var value = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return "submission.ipynb"
    }
    value = URL(fileURLWithPath: value).lastPathComponent
    value = value.replacingOccurrences(of: "/", with: "-")
    value = value.replacingOccurrences(of: "\\", with: "-")
    if !value.lowercased().hasSuffix(".ipynb") {
        value += ".ipynb"
    }
    return value
}

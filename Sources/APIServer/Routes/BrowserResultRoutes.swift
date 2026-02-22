// APIServer/Routes/BrowserResultRoutes.swift
//
// Phase 5: accepts grading results from the student's browser (Pyodide run)
// and enqueues the notebook for an authoritative worker re-run.
//
// Phase 9: merges instructor's hidden test cells back into the student's
// notebook before saving to disk, so the worker grades with the full
// test suite (including secret/release cells stripped from the download).
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
        routes.grouped("api", "v1", "submissions")
            .post("browser-result", use: submitBrowserResult)
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
            .count()
        let attemptNumber = priorCount + 1

        // Create a submission record in "browser-complete" status.
        // A second "pending" submission is NOT created here — the same record
        // transitions to "pending" so the existing worker pull loop picks it up.
        let submission = APISubmission(
            id:            subID,
            testSetupID:   setup.id!,
            zipPath:       nbPath,
            attemptNumber: attemptNumber,
            status:        "browser-complete",
            filename:      "\(subID).ipynb",
            userID:        caller.id
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

        // Enqueue for the authoritative worker re-run by creating a second
        // submission record pointing at the same notebook file.
        let workerSubID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let workerSub = APISubmission(
            id:            workerSubID,
            testSetupID:   setup.id!,
            zipPath:       nbPath,
            attemptNumber: attemptNumber,
            status:        "pending",
            filename:      "\(subID).ipynb",
            userID:        caller.id
        )
        try await workerSub.save(on: req.db)

        req.logger.info("Browser result stored for \(subID); worker job queued as \(workerSubID)")

        return BrowserResultResponse(
            submissionID:       subID,
            workerSubmissionID: workerSubID
        )
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

struct BrowserResultResponse: Content {
    /// ID of the record holding the browser preview result.
    let submissionID: String
    /// ID of the pending worker job (for polling the official result).
    let workerSubmissionID: String
}

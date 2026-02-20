// APIServer/Routes/Web/WebRoutes.swift
//
// Browser-facing routes for the Chickadee MVP web UI.
// No authentication — all submissions are anonymous.
//
//   GET  /                          → index.leaf      (list test setups)
//   GET  /testsetups/new            → setup-new.leaf  (instructor upload form)
//   POST /testsetups/new            → save test setup, redirect to /
//   GET  /testsetups/:id/submit     → submit.leaf     (student submission form)
//   POST /testsetups/:id/submit     → save submission, redirect to /submissions/:id
//   GET  /testsetups/:id/notebook   → notebook.leaf   (JupyterLite in-browser editor)
//   GET  /submissions/:id           → submission.leaf (live results)

import Vapor
import Fluent
import Leaf
import Core
import Foundation

struct WebRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(use: index)
        routes.get("testsetups", "new", use: newSetupForm)
        routes.post("testsetups", "new", use: createSetup)
        routes.get("testsetups", ":testSetupID", "submit", use: submitForm)
        routes.post("testsetups", ":testSetupID", "submit", use: createSubmission)
        routes.get("testsetups", ":testSetupID", "notebook", use: notebookPage)
        routes.get("submissions", ":submissionID", use: submissionPage)
    }

    // MARK: - GET /

    @Sendable
    func index(req: Request) async throws -> View {
        let setups = try await APITestSetup.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let decoder = JSONDecoder()
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        let rows = setups.map { setup -> TestSetupRow in
            let data  = Data(setup.manifest.utf8)
            let props = try? decoder.decode(TestProperties.self, from: data)
            return TestSetupRow(
                id:        setup.id ?? "",
                suiteCount: props?.testSuites.count ?? 0,
                createdAt: setup.createdAt.map { fmt.string(from: $0) } ?? "—"
            )
        }

        return try await req.view.render("index", IndexContext(setups: rows))
    }

    // MARK: - GET /testsetups/new

    @Sendable
    func newSetupForm(req: Request) async throws -> View {
        try await req.view.render("setup-new", EmptyContext())
    }

    // MARK: - POST /testsetups/new

    @Sendable
    func createSetup(req: Request) async throws -> Response {
        let upload = try req.content.decode(TestSetupUpload.self)

        let manifestData = Data(upload.manifest.utf8)
        let decoder      = JSONDecoder()
        let manifest: TestProperties
        do {
            manifest = try decoder.decode(TestProperties.self, from: manifestData)
        } catch {
            throw Abort(.badRequest, reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw Abort(.badRequest, reason: "Unsupported schemaVersion; expected 1")
        }
        guard !manifest.testSuites.isEmpty else {
            throw Abort(.badRequest, reason: "Manifest must list at least one test suite")
        }

        let setupsDir = req.application.testSetupsDirectory
        let setupID   = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath   = setupsDir + "\(setupID).zip"
        try upload.files.write(to: URL(fileURLWithPath: zipPath))

        let encoder = JSONEncoder()
        let stored  = String(data: try encoder.encode(manifest), encoding: .utf8) ?? upload.manifest
        let setup   = APITestSetup(id: setupID, manifest: stored, zipPath: zipPath)
        try await setup.save(on: req.db)

        return req.redirect(to: "/")
    }

    // MARK: - GET /testsetups/:id/submit

    @Sendable
    func submitForm(req: Request) async throws -> View {
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.view.render("submit", SubmitContext(testSetupID: setupID))
    }

    // MARK: - POST /testsetups/:id/submit

    @Sendable
    func createSubmission(req: Request) async throws -> Response {
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body    = try req.content.decode(SubmitFormBody.self)
        let subsDir = req.application.submissionsDirectory
        let subID   = "sub_\(UUID().uuidString.lowercased().prefix(8))"

        // Detect whether the upload is a zip by checking PK magic bytes.
        let isZip     = body.files.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
        let ext       = body.uploadFilename.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "zip"
        let storedExt = isZip ? "zip" : ext
        let filePath  = subsDir + "\(subID).\(storedExt)"
        try body.files.write(to: URL(fileURLWithPath: filePath))

        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setupID,
            zipPath:       filePath,
            attemptNumber: priorCount + 1,
            filename:      isZip ? nil : body.uploadFilename
        )
        try await submission.save(on: req.db)

        return req.redirect(to: "/submissions/\(subID)")
    }

    // MARK: - GET /testsetups/:id/notebook

    @Sendable
    func notebookPage(req: Request) async throws -> View {
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.view.render("notebook", NotebookContext(testSetupID: setupID))
    }

    // MARK: - GET /submissions/:id

    @Sendable
    func submissionPage(req: Request) async throws -> View {
        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let isPending = submission.status == "pending" || submission.status == "assigned"
        var buildFailed     = false
        var compilerOutput: String? = nil
        var outcomes:       [OutcomeRow] = []
        var passCount       = 0
        var totalTests      = 0
        var executionTimeMs = 0

        if !isPending {
            if let result = try await APIResult.query(on: req.db)
                .filter(\.$submissionID == subID)
                .sort(\.$receivedAt, .descending)
                .first()
            {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let data       = result.collectionJSON.data(using: .utf8),
                   let collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
                {
                    buildFailed     = collection.buildStatus == .failed
                    compilerOutput  = collection.compilerOutput
                    passCount       = collection.passCount
                    totalTests      = collection.totalTests
                    executionTimeMs = collection.executionTimeMs
                    outcomes = collection.outcomes.map { o in
                        OutcomeRow(
                            testName:        o.testName,
                            tier:            o.tier.rawValue,
                            status:          o.status.rawValue,
                            shortResult:     o.shortResult,
                            longResult:      o.longResult,
                            executionTimeMs: o.executionTimeMs
                        )
                    }
                }
            }
        }

        let ctx = SubmissionContext(
            submissionID:    subID,
            testSetupID:     submission.testSetupID,
            status:          submission.status,
            attemptNumber:   submission.attemptNumber ?? 1,
            isPending:       isPending,
            buildFailed:     buildFailed,
            compilerOutput:  compilerOutput,
            outcomes:        outcomes,
            passCount:       passCount,
            totalTests:      totalTests,
            executionTimeMs: executionTimeMs
        )
        return try await req.view.render("submission", ctx)
    }
}

// MARK: - Context types

private struct EmptyContext: Encodable {}

private struct TestSetupRow: Encodable {
    let id: String
    let suiteCount: Int
    let createdAt: String
}

private struct IndexContext: Encodable {
    let setups: [TestSetupRow]
}

private struct SubmitContext: Encodable {
    let testSetupID: String
}

private struct NotebookContext: Encodable {
    let testSetupID: String
}

private struct OutcomeRow: Encodable {
    let testName: String
    let tier: String
    let status: String
    let shortResult: String
    let longResult: String?
    let executionTimeMs: Int
}

private struct SubmissionContext: Encodable {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let isPending: Bool
    let buildFailed: Bool
    let compilerOutput: String?
    let outcomes: [OutcomeRow]
    let passCount: Int
    let totalTests: Int
    let executionTimeMs: Int
}

// MARK: - Multipart body for code submission

private struct SubmitFormBody: Content {
    var files: Data
    /// Original filename from the browser's multipart upload (nil for older clients).
    var uploadFilename: String?
}

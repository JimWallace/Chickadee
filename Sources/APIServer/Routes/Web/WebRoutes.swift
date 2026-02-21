// APIServer/Routes/Web/WebRoutes.swift
//
// Browser-facing routes for the Chickadee web UI.
// All routes in this collection require authentication (enforced by RoleMiddleware
// in routes.swift). Instructor-only routes (testsetups/new) are in a separate
// group in routes.swift.
//
//   GET  /                          → index.leaf      (assignments)
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
        let user = try req.auth.require(APIUser.self)

        let decoder = JSONDecoder()
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        // Fetch all open assignments to join title + dueAt onto setup rows.
        let openAssignments = try await APIAssignment.query(on: req.db)
            .filter(\.$isOpen == true)
            .all()
        let assignmentBySetup = Dictionary(
            openAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let setups: [APITestSetup]
        if user.isInstructor {
            // Instructors and admins see all test setups.
            setups = try await APITestSetup.query(on: req.db)
                .sort(\.$createdAt, .descending)
                .all()
        } else {
            // Students see only test setups that have an open published assignment.
            let publishedIDs = Set(openAssignments.map(\.testSetupID))
            guard !publishedIDs.isEmpty else {
                return try await req.view.render("index",
                    IndexContext(setups: [], currentUser: req.currentUserContext))
            }
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ publishedIDs)
                .sort(\.$createdAt, .descending)
                .all()
        }

        let rows = setups.map { setup -> TestSetupRow in
            let setupID    = setup.id ?? ""
            let data       = Data(setup.manifest.utf8)
            let props      = try? decoder.decode(TestProperties.self, from: data)
            let assignment = assignmentBySetup[setupID]
            return TestSetupRow(
                id:         setupID,
                title:      assignment?.title,
                suiteCount: props?.testSuites.count ?? 0,
                createdAt:  setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                dueAt:      assignment?.dueAt.map { fmt.string(from: $0) }
            )
        }

        return try await req.view.render("index",
            IndexContext(setups: rows, currentUser: req.currentUserContext))
    }

    // MARK: - GET /testsetups/new

    @Sendable
    func newSetupForm(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }
        return try await req.view.render("setup-new",
            BaseContext(currentUser: req.currentUserContext))
    }

    // MARK: - POST /testsetups/new

    @Sendable
    func createSetup(req: Request) async throws -> Response {
        let setupUser = try req.auth.require(APIUser.self)
        guard setupUser.isInstructor else { throw Abort(.forbidden) }
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
        return try await req.view.render("submit",
            SubmitContext(testSetupID: setupID, currentUser: req.currentUserContext))
    }

    // MARK: - POST /testsetups/:id/submit

    @Sendable
    func createSubmission(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

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

        // Attempt number is scoped to this student for this test setup.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == user.id)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setupID,
            zipPath:       filePath,
            attemptNumber: priorCount + 1,
            filename:      isZip ? nil : body.uploadFilename,
            userID:        user.id
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
        return try await req.view.render("notebook",
            NotebookContext(testSetupID: setupID, currentUser: req.currentUserContext))
    }

    // MARK: - GET /submissions/:id

    @Sendable
    func submissionPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)

        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Students may only view their own submissions.
        if !user.isInstructor {
            guard submission.userID == user.id else {
                throw Abort(.forbidden)
            }
        }

        // "browser-complete" means the browser run finished but worker hasn't yet.
        let isPending         = submission.status == "pending" || submission.status == "assigned"
        let isBrowserComplete = submission.status == "browser-complete"

        var buildFailed     = false
        var compilerOutput: String? = nil
        var outcomes:       [OutcomeRow] = []
        var passCount       = 0
        var totalTests      = 0
        var executionTimeMs = 0
        var resultSource    = ""   // "browser" | "worker" | ""

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Prefer the worker result (official); fall back to browser result.
        let allResults = try await APIResult.query(on: req.db)
            .filter(\.$submissionID == subID)
            .sort(\.$receivedAt, .descending)
            .all()

        let workerResult  = allResults.first { ($0.source ?? "worker") == "worker" }
        let browserResult = allResults.first { $0.source == "browser" }
        let displayResult = workerResult ?? browserResult

        if let result = displayResult {
            resultSource = result.source ?? "worker"
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

        let ctx = SubmissionContext(
            submissionID:      subID,
            testSetupID:       submission.testSetupID,
            status:            submission.status,
            attemptNumber:     submission.attemptNumber ?? 1,
            isPending:         isPending,
            isBrowserComplete: isBrowserComplete,
            resultSource:      resultSource,
            buildFailed:       buildFailed,
            compilerOutput:    compilerOutput,
            outcomes:          outcomes,
            passCount:         passCount,
            totalTests:        totalTests,
            executionTimeMs:   executionTimeMs,
            currentUser:       req.currentUserContext
        )
        return try await req.view.render("submission", ctx)
    }
}

// MARK: - Context types

private struct BaseContext: Encodable {
    let currentUser: CurrentUserContext?
}

private struct TestSetupRow: Encodable {
    let id: String
    let title: String?      // from APIAssignment; nil when instructor sees unpublished setups
    let suiteCount: Int
    let createdAt: String
    let dueAt: String?      // formatted due date, nil if no assignment or no due date
}

private struct IndexContext: Encodable {
    let setups: [TestSetupRow]
    let currentUser: CurrentUserContext?
}

private struct SubmitContext: Encodable {
    let testSetupID: String
    let currentUser: CurrentUserContext?
}

private struct NotebookContext: Encodable {
    let testSetupID: String
    let currentUser: CurrentUserContext?
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
    /// True when the browser run is done but the worker hasn't reported yet.
    let isBrowserComplete: Bool
    /// "browser" or "worker" — which result is currently displayed.
    let resultSource: String
    let buildFailed: Bool
    let compilerOutput: String?
    let outcomes: [OutcomeRow]
    let passCount: Int
    let totalTests: Int
    let executionTimeMs: Int
    let currentUser: CurrentUserContext?
}

// MARK: - Multipart body for code submission

private struct SubmitFormBody: Content {
    var files: Data
    /// Original filename from the browser's multipart upload (nil for older clients).
    var uploadFilename: String?
}

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
import Crypto

struct WebRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(use: index)
        routes.get("testsetups", "new", use: newSetupForm)
        routes.post("testsetups", "new", use: createSetup)
        routes.get("testsetups", ":testSetupID", "submit", use: submitForm)
        routes.post("testsetups", ":testSetupID", "submit", use: createSubmission)
        routes.get("testsetups", ":testSetupID", "history", use: submissionHistoryPage)
        routes.get("testsetups", ":testSetupID", "notebook", use: notebookPage)
        routes.get("testsetups", ":testSetupID", "notebook", "source", use: notebookSource)
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

        // Load assignments so home can show status/due information in table rows.
        let allAssignments = try await APIAssignment.query(on: req.db).all()
        let openAssignments = allAssignments.filter(\.isOpen)
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
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

        var latestSubmissionBySetupID: [String: LatestSubmissionItem] = [:]
        var submissionCountBySetupID: [String: Int] = [:]
        var bestGradePercentBySetupID: [String: Int] = [:]
        if let userID = user.id {
            let setupIDs = setups.compactMap(\.id)
            if !setupIDs.isEmpty {
                let submissions = try await APISubmission.query(on: req.db)
                    .filter(\.$userID == userID)
                    .filter(\.$testSetupID ~~ setupIDs)
                    .filter(\.$kind == APISubmission.Kind.student)
                    .sort(\.$submittedAt, .descending)
                    .all()

                var grouped: [String: [APISubmission]] = [:]
                for submission in submissions {
                    grouped[submission.testSetupID, default: []].append(submission)
                }

                for (setupID, items) in grouped {
                    submissionCountBySetupID[setupID] = items.count
                    if let latest = items.first {
                        let when = latest.submittedAt.map { fmt.string(from: $0) } ?? "—"
                        latestSubmissionBySetupID[setupID] = LatestSubmissionItem(
                            submissionID: latest.id ?? "",
                            submittedAtText: when
                        )
                    }
                }

                let submissionIDs = submissions.compactMap(\.id)
                if !submissionIDs.isEmpty {
                    let resultRows = try await APIResult.query(on: req.db)
                        .filter(\.$submissionID ~~ submissionIDs)
                        .sort(\.$receivedAt, .descending)
                        .all()

                    // Keep one preferred result per submission:
                    // worker result first; browser result only if no worker exists.
                    var preferredResultBySubmissionID: [String: APIResult] = [:]
                    for row in resultRows {
                        let key = row.submissionID
                        if let existing = preferredResultBySubmissionID[key] {
                            let existingSource = existing.source ?? "worker"
                            let currentSource = row.source ?? "worker"
                            if existingSource == "worker" { continue }
                            if currentSource == "worker" {
                                preferredResultBySubmissionID[key] = row
                            }
                        } else {
                            preferredResultBySubmissionID[key] = row
                        }
                    }

                    for submission in submissions {
                        guard let subID = submission.id,
                              let result = preferredResultBySubmissionID[subID],
                              let gradePercent = gradePercentFromCollectionJSON(result.collectionJSON) else {
                            continue
                        }
                        let setupID = submission.testSetupID
                        let existing = bestGradePercentBySetupID[setupID] ?? 0
                        if gradePercent > existing {
                            bestGradePercentBySetupID[setupID] = gradePercent
                        }
                    }
                }
            }
        }

        let rows = setups.map { setup -> TestSetupRow in
            let setupID    = setup.id ?? ""
            let data       = Data(setup.manifest.utf8)
            let props      = try? decoder.decode(TestProperties.self, from: data)
            let assignment = assignmentBySetup[setupID]
            let latestSubmission = latestSubmissionBySetupID[setupID]
            let submissionCount = submissionCountBySetupID[setupID] ?? 0
            let status: String
            if let assignment {
                status = assignment.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }
            return TestSetupRow(
                id:         setupID,
                title:      assignment?.title,
                suiteCount: props?.testSuites.count ?? 0,
                createdAt:  setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                dueAt:      assignment?.dueAt.map { fmt.string(from: $0) },
                status:     status,
                isOpen:     assignment?.isOpen ?? false,
                submissionCount: submissionCount,
                hasLatestSubmission: latestSubmission != nil,
                latestSubmissionID: latestSubmission?.submissionID ?? "",
                latestSubmittedAtText: latestSubmission?.submittedAtText ?? "—",
                additionalSubmissionCount: max(submissionCount - 1, 0),
                bestGradeText: bestGradePercentBySetupID[setupID].map { "\($0)%" }
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
        let ext: String = {
            if isZip { return "zip" }
            return inferredRawSubmissionExtension(data: body.files, uploadFilename: body.uploadFilename)
        }()
        let storedExt = isZip ? "zip" : ext
        let filePath  = subsDir + "\(subID).\(storedExt)"
        try body.files.write(to: URL(fileURLWithPath: filePath))
        let fallbackFilename = isZip ? nil : (body.uploadFilename ?? "submission.\(storedExt)")

        // Attempt number is scoped to this student for this test setup.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == user.id)
            .filter(\.$kind == APISubmission.Kind.student)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setupID,
            zipPath:       filePath,
            attemptNumber: priorCount + 1,
            filename:      fallbackFilename,
            userID:        user.id,
            kind:          APISubmission.Kind.student
        )
        try await submission.save(on: req.db)
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

        return req.redirect(to: "/submissions/\(subID)")
    }

    // MARK: - GET /testsetups/:id/history

    @Sendable
    func submissionHistoryPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let title = assignment?.title ?? setupID

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()

        let submissionIDs = submissions.compactMap(\.id)
        var preferredResultBySubmissionID: [String: APIResult] = [:]
        if !submissionIDs.isEmpty {
            let results = try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .sort(\.$receivedAt, .descending)
                .all()
            for row in results {
                let key = row.submissionID
                if let existing = preferredResultBySubmissionID[key] {
                    let existingSource = existing.source ?? "worker"
                    let currentSource = row.source ?? "worker"
                    if existingSource == "worker" { continue }
                    if currentSource == "worker" {
                        preferredResultBySubmissionID[key] = row
                    }
                } else {
                    preferredResultBySubmissionID[key] = row
                }
            }
        }

        let rows = submissions.map { submission -> SubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let result = preferredResultBySubmissionID[subID],
               let pct = gradePercentFromCollectionJSON(result.collectionJSON) {
                gradeText = "\(pct)%"
            } else {
                gradeText = "—"
            }
            return SubmissionHistoryRow(
                submissionID: subID,
                attemptNumber: submission.attemptNumber ?? 1,
                status: submission.status,
                submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
                gradeText: gradeText
            )
        }

        return try await req.view.render("submission-history",
            SubmissionHistoryContext(
                testSetupID: setupID,
                assignmentTitle: title,
                rows: rows,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /testsetups/:id/notebook

    @Sendable
    func notebookPage(req: Request) async throws -> View {
        struct NotebookQuery: Content {
            var title: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let query = try? req.query.decode(NotebookQuery.self)
        let queryTitle = (query?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let dbTitle = (assignment?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentTitle = {
            if !queryTitle.isEmpty { return queryTitle }
            if !dbTitle.isEmpty { return dbTitle }
            return "Assignment"
        }()
        let fallbackNotebookFilename = notebookFilenameForJupyterLite(title: assignmentTitle)
        let selectedNotebook = try await latestNotebookSubmissionData(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup
        )
        let displayFilename = safeNotebookFilename(
            preferred: selectedNotebook.filename,
            fallbackTitle: fallbackNotebookFilename
        )
        let userSlug = userID.uuidString.lowercased()
        let jupyterLiteNotebookPath = "users/\(userSlug)/\(displayFilename)"

        // Materialize notebook into all likely JupyterLite file roots.
        // Different entrypoints may resolve baseUrl differently and look under
        // /files, /jupyterlite/files, /jupyterlite/lab/files, or /jupyterlite/notebooks/files.
        let fileRoots = [
            req.application.directory.publicDirectory + "files/",
            req.application.directory.publicDirectory + "jupyterlite/files/",
            req.application.directory.publicDirectory + "jupyterlite/lab/files/",
            req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
        ]
        let nbData = selectedNotebook.data
        for root in fileRoots {
            let userDir = root + "users/\(userSlug)/"
            try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
            try nbData.write(to: URL(fileURLWithPath: userDir + displayFilename))
            try nbData.write(to: URL(fileURLWithPath: userDir + "assignment.ipynb"))
        }
        let encodedPath = jupyterLiteNotebookPath.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)
            ?? "assignment.ipynb"
        let workspaceID = "\(setupID)-\(userSlug)-student"
        let editorURL = "/jupyterlite/lab/index.html?workspace=\(workspaceID)&reset=&path=\(encodedPath)"

        return try await req.view.render("notebook",
            NotebookContext(
                testSetupID: setupID,
                assignmentTitle: assignmentTitle,
                notebookURL: "/testsetups/\(setupID)/notebook/source",
                jupyterLiteEditorURL: editorURL,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /testsetups/:id/notebook/source

    @Sendable
    func notebookSource(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let payload = try await latestNotebookSubmissionData(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup
        ).data

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: payload))
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
        var gradePercent    = 0
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
                gradePercent    = collection.totalTests > 0
                    ? Int((Double(collection.passCount) / Double(collection.totalTests) * 100).rounded())
                    : 0
                outcomes = collection.outcomes.map { o in
                    OutcomeRow(
                        testName:        o.testName,
                        tier:            o.tier.rawValue,
                        status:          o.status.rawValue,
                        shortResult:     o.shortResult,
                        readableOutput:  readableScriptOutput(from: o.longResult),
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
            gradePercent:      gradePercent,
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
    let status: String      // "unpublished" | "open" | "closed"
    let isOpen: Bool
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
}

private struct LatestSubmissionItem: Encodable {
    let submissionID: String
    let submittedAtText: String
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
    let assignmentTitle: String
    let notebookURL: String
    let jupyterLiteEditorURL: String
    let currentUser: CurrentUserContext?
}

private struct SubmissionHistoryContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let rows: [SubmissionHistoryRow]
    let currentUser: CurrentUserContext?
}

private struct SubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
}

private struct OutcomeRow: Encodable {
    let testName: String
    let tier: String
    let status: String
    let shortResult: String
    let readableOutput: String?
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
    let gradePercent: Int
    let executionTimeMs: Int
    let currentUser: CurrentUserContext?
}

private func notebookFilenameForJupyterLite(title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    var value = trimmed.isEmpty ? "Assignment" : trimmed
    value = value.replacingOccurrences(of: "/", with: "-")
    value = value.replacingOccurrences(of: "\\", with: "-")
    value = value.replacingOccurrences(of: ":", with: "-")
    value = value.replacingOccurrences(of: "\n", with: " ")
    value = value.replacingOccurrences(of: "\r", with: " ")
    if !value.lowercased().hasSuffix(".ipynb") {
        value += ".ipynb"
    }
    return value
}

private func safeNotebookFilename(preferred: String?, fallbackTitle: String) -> String {
    let fallback = notebookFilenameForJupyterLite(title: fallbackTitle)
    guard var value = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return fallback
    }
    value = URL(fileURLWithPath: value).lastPathComponent
    value = value.replacingOccurrences(of: "/", with: "-")
    value = value.replacingOccurrences(of: "\\", with: "-")
    value = value.replacingOccurrences(of: "\n", with: " ")
    value = value.replacingOccurrences(of: "\r", with: " ")
    if !value.lowercased().hasSuffix(".ipynb") {
        value += ".ipynb"
    }
    return value
}

private func latestNotebookSubmissionData(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup
) async throws -> (data: Data, filename: String?) {
    let submissions = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$userID == userID)
        .filter(\.$kind == APISubmission.Kind.student)
        .sort(\.$submittedAt, .descending)
        .all()

    for submission in submissions {
        let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
        let nameExt = (submission.filename ?? "").lowercased()
        guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
            continue
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: submission.zipPath)),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            continue
        }
        return (data, submission.filename)
    }

    let fallbackFilename: String? = {
        guard let path = fallbackSetup.notebookPath, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()
    return (try notebookData(for: fallbackSetup), fallbackFilename)
}

private func gradePercentFromCollectionJSON(_ collectionJSON: String) -> Int? {
    guard let data = collectionJSON.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let passCount = root["passCount"] as? Int,
          let totalTests = root["totalTests"] as? Int,
          totalTests > 0 else {
        return nil
    }
    return Int((Double(passCount) / Double(totalTests) * 100).rounded())
}

private func readableScriptOutput(from raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let payload = firstJSONObject(in: trimmed) {
        var lines: [String] = []
        if let shortResult = payload["shortResult"] as? String,
           !shortResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(shortResult)
        }
        if let error = payload["error"] as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Error: \(error)")
        }
        if let test = payload["test"] as? String,
           !test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Script: \(test)")
        }
        if let status = payload["status"] as? String,
           !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Status: \(status)")
        }
        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        if let pretty = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
    }

    // Fallback: show first few meaningful lines inline.
    let lines = trimmed
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }
    let preview = Array(lines.prefix(3))
    if lines.count > preview.count {
        return preview.joined(separator: "\n") + "\n…"
    }
    return preview.joined(separator: "\n")
}

private func firstJSONObject(in text: String) -> [String: Any]? {
    // Most runner JSON payloads are emitted as a single line near the end.
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    for line in lines.reversed() {
        guard line.first == "{", line.last == "}" else { continue }
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }
        return value
    }
    guard text.first == "{", text.last == "}",
          let data = text.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return value
}

// MARK: - Multipart body for code submission

private struct SubmitFormBody: Content {
    var files: Data
    /// Original filename from the browser's multipart upload (nil for older clients).
    var uploadFilename: String?
}

private func inferredRawSubmissionExtension(data: Data, uploadFilename: String?) -> String {
    if let uploadFilename {
        let ext = URL(fileURLWithPath: uploadFilename).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty {
            return ext.lowercased()
        }
    }

    // Heuristic: notebook uploads are JSON with "nbformat" key.
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       json["nbformat"] != nil {
        return "ipynb"
    }

    return "txt"
}

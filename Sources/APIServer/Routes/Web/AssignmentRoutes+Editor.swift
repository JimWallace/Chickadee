// APIServer/Routes/Web/AssignmentRoutes+Editor.swift
//
// Instructor assignment editor routes: file downloads, edit/save, script
// CRUD, and notebook scanning. All routes registered in AssignmentRoutes.boot().

import Vapor
import Fluent
import Core
import Foundation
import Crypto

extension AssignmentRoutes {
    // MARK: - GET /instructor/:assignmentID/files/notebook

    @Sendable
    func downloadCurrentNotebookFile(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let data = try notebookData(for: setup)
        let downloadName = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            hasValidationSolution: assignment.validationSubmissionID != nil
        ).assignmentFile.name
        return buildFileResponse(data: data, filename: downloadName)
    }

    // MARK: - GET /instructor/:assignmentID/files/item?name=<filename>

    @Sendable
    func downloadCurrentSetupItem(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct FileQuery: Content {
            let name: String
        }
        let q = try req.query.decode(FileQuery.self)
        let fileName = (q.name as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName == q.name else {
            throw Abort(.badRequest, reason: "Invalid file name")
        }

        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: fileName) else {
            throw Abort(.notFound, reason: "File '\(fileName)' not found in setup")
        }
        return buildFileResponse(data: data, filename: fileName)
    }

    // MARK: - GET /instructor/:assignmentID/files/solution

    @Sendable
    func downloadCurrentSolutionFile(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Look for a solution.* entry inside the test setup zip.
        let solutionZipEntry = listZipEntries(zipPath: setup.zipPath)
            .first(where: { $0.hasPrefix("solution.") })
        if let entryName = solutionZipEntry,
           let data = extractZipEntry(zipPath: setup.zipPath, entryName: entryName) {
            return buildFileResponse(data: data, filename: entryName)
        }

        // Fall back to the most recent validation submission, preserving
        // the instructor's original filename (e.g. bmi.py, dna.py).
        if let validationID = assignment.validationSubmissionID,
           let validationSubmission = try await APISubmission.find(validationID, on: req.db),
           let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
           !data.isEmpty {
            return buildFileResponse(data: data, filename: validationSubmission.filename ?? "solution.ipynb")
        }

        if let fallbackSubmission = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first(),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
           !data.isEmpty {
            return buildFileResponse(data: data, filename: fallbackSubmission.filename ?? "solution.ipynb")
        }

        throw Abort(.notFound, reason: "No solution notebook is available for this assignment yet")
    }

    // MARK: - POST /instructor/:assignmentID/edit/save

    @Sendable
    func saveEditedAssignment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct SaveBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
        }
        struct SaveBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
        }

        let bodyMany = try? req.content.decode(SaveBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(SaveBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw Abort(.badRequest, reason: "Invalid assignment upload payload")
        }

        let assignmentName = try multipartTextField(named: ["assignmentName"], from: req)
            ?? bodyMany?.assignmentName
            ?? bodySingle?.assignmentName
        let dueAtRaw = try multipartTextField(named: ["dueAt"], from: req)
            ?? bodyMany?.dueAt
            ?? bodySingle?.dueAt
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFilesRaw = try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? bodyMany?.suiteFiles
            ?? (bodySingle?.suiteFiles.map { [$0] } ?? [])
        let suiteConfigRaw = try multipartTextField(named: ["suiteConfig"], from: req)
            ?? bodyMany?.suiteConfig
            ?? bodySingle?.suiteConfig

        let title = (assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(dueAtRaw)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        let uploadedSuiteFiles = suiteFilesRaw.filter { $0.data.readableBytes > 0 }

        let hasUploadedAssignmentNotebook = assignmentNotebookFile?.data.readableBytes ?? 0 > 0
        // Marmoset-style worker-mode imports often have no starter .ipynb.
        // Fall back to an empty notebook so the edit can proceed without
        // requiring the instructor to upload one on every save.
        // The empty notebook produces no .py code when extractNotebooksToCode
        // runs, so it doesn't conflict with the student submission.
        let assignmentNotebookRaw: Data = {
            guard let assignmentNotebookFile, hasUploadedAssignmentNotebook else {
                return (try? notebookData(for: setup)) ?? minimalEmptyNotebookData()
            }
            return Data(assignmentNotebookFile.data.readableBytesView)
        }()
        guard !assignmentNotebookRaw.isEmpty,
              (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required%20and%20must%20be%20valid%20JSON"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        // Resolve solution data + filename. Prefer newly uploaded file, then zip entry, then prior submission.
        var solutionFilename = "solution.ipynb"
        let solutionNotebookRaw: Data = {
            if let solutionNotebookFile, solutionNotebookFile.data.readableBytes > 0 {
                solutionFilename = solutionNotebookFile.filename.isEmpty ? "solution.ipynb" : solutionNotebookFile.filename
                return Data(solutionNotebookFile.data.readableBytesView)
            }
            let archiveFiles = listZipEntries(zipPath: setup.zipPath)
            if let solutionEntry = archiveFiles.first(where: { $0.hasPrefix("solution.") }),
               let data = extractZipEntry(zipPath: setup.zipPath, entryName: solutionEntry) {
                solutionFilename = solutionEntry
                return data
            }
            return Data()
        }()
        var resolvedSolutionNotebookRaw = solutionNotebookRaw
        if resolvedSolutionNotebookRaw.isEmpty,
           let existingSolution = try await loadExistingSolution(req: req, assignment: assignment) {
            resolvedSolutionNotebookRaw = existingSolution.data
            solutionFilename = existingSolution.filename
        }
        guard !resolvedSolutionNotebookRaw.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required%20for%20validation"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }
        let solutionIsNotebook = (try? JSONSerialization.jsonObject(with: resolvedSolutionNotebookRaw)) != nil

        let resolvedSuite: ResolvedEditSuiteFiles
        do {
            resolvedSuite = try resolveEditSuiteFiles(
                setupZipPath: setup.zipPath,
                setupManifestJSON: setup.manifest,
                uploadedSuiteFiles: uploadedSuiteFiles,
                suiteConfigJSON: suiteConfigRaw
            )
        } catch {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=\(urlEncode(error.localizedDescription))"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }
        guard !resolvedSuite.files.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Add%20or%20keep%20at%20least%20one%20test%20suite%20or%20support%20file"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)
        let notebookPath: String = {
            if hasUploadedAssignmentNotebook {
                let fallbackName = setup.notebookPath
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? "assignment.ipynb"
                let uploadedName = assignmentNotebookFile?.filename
                let filename = notebookFilenameForStorage(uploadedName: uploadedName, fallback: fallbackName)
                let dir = req.application.testSetupsDirectory + "notebooks/\(setup.id!)/"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return dir + filename
            }
            return setup.notebookPath ?? (req.application.testSetupsDirectory + "\(setup.id!).ipynb")
        }()
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))

        let setupPackage = try createRunnerSetupZip(
            suiteFiles: resolvedSuite.files,
            suiteConfigJSON: resolvedSuite.reindexedSuiteConfigJSON,
            zipPath: setup.zipPath
        )
        guard !setupPackage.testSuites.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Select%20at%20least%20one%20test%20file%20in%20the%20suite%20list"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }
        // Preserve the grading mode and starterNotebook already stored in the
        // manifest — editing the suite files must not silently reset them.
        let existingManifestDict: [String: Any] = {
            guard let data = setup.manifest.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return [:] }
            return dict
        }()
        let existingGradingMode = existingManifestDict["gradingMode"] as? String ?? "worker"
        let existingStarterNotebook = existingManifestDict["starterNotebook"] as? String ?? "assignment.ipynb"
        setup.manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile,
            gradingMode: existingGradingMode,
            starterNotebook: existingStarterNotebook
        )
        setup.notebookPath = notebookPath
        try await setup.save(on: req.db)
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: setup.id!,
            testSuiteScripts: Set(setupPackage.testSuites.map { $0.script }),
            testSetupsDirectory: req.application.testSetupsDirectory
        )

        assignment.title = title
        assignment.dueAt = due
        assignment.isOpen = false
        assignment.validationStatus = "pending"

        let solutionDataToSubmit = solutionIsNotebook
            ? normalizeNotebookForJupyterLite(resolvedSolutionNotebookRaw)
            : resolvedSolutionNotebookRaw
        let validationSubmissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: setup.id!,
            solutionNotebookData: solutionDataToSubmit,
            filename: solutionFilename
        )
        assignment.validationSubmissionID = validationSubmissionID
        try await assignment.save(on: req.db)

        // Kick off the runner if needed, then return immediately.
        // Validation runs in the background; the instructor sees "pending" on the
        // assignments list and can refresh to see the outcome.
        await ensureValidationRunnerAvailability(req: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - GET /instructor/:assignmentID/scripts/:filename
    //
    // Returns the raw text content of a single file from the setup zip.

    @Sendable
    func getScript(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr    = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        guard let content = readScriptFromZip(zipPath: setup.zipPath, filename: filename) else {
            throw Abort(.notFound, reason: "File '\(filename)' not found in setup zip")
        }
        var headers = HTTPHeaders()
        headers.contentType = .plainText
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    // MARK: - PUT /instructor/:assignmentID/scripts/:filename
    //
    // Replaces the content of an existing script in the setup zip.
    // Body (JSON): { "content": "..." }

    @Sendable
    func updateScript(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr    = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        struct UpdateBody: Content { var content: String }
        let body = try req.content.decode(UpdateBody.self)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        // Verify the file exists before writing.
        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw Abort(.notFound, reason: "File '\(filename)' not found in setup zip")
        }

        do {
            try updateScriptInZip(zipPath: setup.zipPath, filename: filename, content: body.content)
        } catch ScriptZipError.zipFailed {
            throw Abort(.internalServerError, reason: "Failed to update setup zip")
        }
        return .noContent
    }

    // MARK: - POST /instructor/:assignmentID/scripts
    //
    // Creates a new script file in the setup zip and adds a TestSuiteEntry
    // to the manifest (default: public tier, 1 point, no dependencies).
    // Body (JSON): { "filename": "test_new.py", "content": "...", "tier": "public", "points": 1 }

    @Sendable
    func createScript(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)

        struct CreateBody: Content {
            var filename: String
            var content:  String
            var tier:     String?
            var points:   Int?
            var isTest:   Bool?
        }
        let body = try req.content.decode(CreateBody.self)

        // Validate filename: must be a simple filename (no path separators).
        let cleaned = sanitizeSuiteFilename(body.filename)
        guard !cleaned.isEmpty, cleaned == body.filename else {
            throw Abort(.badRequest, reason: "Invalid filename '\(body.filename)'")
        }

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        // Reject duplicate filenames.
        if listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
            throw Abort(.conflict, reason: "A file named '\(cleaned)' already exists in this setup")
        }

        try updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: body.content)

        let tier       = normalizeTier(body.tier, isTest: body.isTest)
        let points     = max(1, body.points ?? 1)
        let shouldTest = tier != "support"

        if shouldTest {
            let entry = ConfiguredSuiteEntry(
                script: cleaned, tier: tier, order: 0,
                dependsOn: [], points: points, displayName: nil
            )
            if let updated = updateManifestAddingScript(manifestJSON: setup.manifest, entry: entry) {
                setup.manifest = updated
                try await setup.save(on: req.db)
            }
        }

        struct CreatedResponse: Content {
            var filename: String
            var tier: String
            var points: Int
            var isTest: Bool
            var editURL: String
        }
        let resp = CreatedResponse(
            filename: cleaned,
            tier: tier,
            points: points,
            isTest: shouldTest,
            editURL: "/instructor/\(idStr)/scripts/\(urlEncode(cleaned))"
        )
        return try await resp.encodeResponse(status: .created, for: req)
    }

    // MARK: - DELETE /instructor/:assignmentID/scripts/:filename
    //
    // Removes a script from the setup zip and manifest.
    // Returns 409 if other scripts in the manifest depend on this one.

    @Sendable
    func deleteScript(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr    = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw Abort(.notFound, reason: "File '\(filename)' not found in setup zip")
        }

        let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
        guard dependents.isEmpty else {
            throw Abort(.conflict,
                reason: "Cannot delete '\(filename)': the following scripts depend on it: \(dependents.joined(separator: ", "))")
        }

        do {
            try removeScriptFromZip(zipPath: setup.zipPath, filename: filename)
        } catch ScriptZipError.zipFailed {
            throw Abort(.internalServerError, reason: "Failed to update setup zip")
        }

        if let updated = updateManifestRemovingScript(manifestJSON: setup.manifest, filename: filename) {
            setup.manifest = updated
            try await setup.save(on: req.db)
        }
        return .noContent
    }

    // MARK: - POST /instructor/scan-notebook
    //
    // Scans a solution notebook for Python function definitions and returns
    // one entry per public top-level function, along with pre-generated
    // script templates.
    //
    // Body: raw .ipynb JSON bytes (Content-Type: application/json or application/octet-stream)

    @Sendable
    func scanNotebook(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        guard let buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Request body is empty")
        }
        let notebookData = Data(buffer.readableBytesView)
        guard !notebookData.isEmpty else {
            throw Abort(.badRequest, reason: "Notebook data is empty")
        }

        let functions = scanNotebookForFunctions(notebookData)

        struct FunctionResult: Content {
            var name: String
            var paramNames: [String]
            var paramCount: Int
            var hasTypeHints: Bool
            var hasDocstring: Bool
            var templates: [TestTemplateInfo]
        }

        let results = functions.map { fn in
            FunctionResult(
                name: fn.name,
                paramNames: fn.paramNames,
                paramCount: fn.paramCount,
                hasTypeHints: fn.hasTypeHints,
                hasDocstring: fn.hasDocstring,
                templates: allTemplateInfos(functionName: fn.name, paramNames: fn.paramNames)
            )
        }

        return try await results.encodeResponse(for: req)
    }
}

// MARK: - Route parameter helpers

/// Extracts and validates the `:filename` route parameter.
/// Rejects any value that contains path separators or traversal components.
private func safeScriptFilename(from req: Request) throws -> String {
    guard let raw = req.parameters.get("filename"), !raw.isEmpty else {
        throw Abort(.badRequest, reason: "Missing filename parameter")
    }
    let cleaned = (raw as NSString).lastPathComponent
    guard cleaned == raw, !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
        throw Abort(.badRequest, reason: "Invalid filename '\(raw)'")
    }
    return cleaned
}

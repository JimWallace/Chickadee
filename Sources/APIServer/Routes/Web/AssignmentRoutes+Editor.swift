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
            solutionFilename: nil
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
                solutionFilename = submissionFilenameForStorage(
                    uploadedName: solutionNotebookFile.filename,
                    fallback: "solution.ipynb"
                )
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
        if resolvedSolutionNotebookRaw.isEmpty, let userID = user.id,
           let draftData = draftNotebookData(
               req: req, setupID: setup.id!, userID: userID, fileKind: .solution,
               fallbackPath: draftSolutionNotebookPath(
                   testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)) {
            resolvedSolutionNotebookRaw = draftData
        }
        guard !resolvedSolutionNotebookRaw.isEmpty else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required%20for%20validation"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }
        let solutionIsNotebook = (try? JSONSerialization.jsonObject(with: resolvedSolutionNotebookRaw)) != nil

        // As of v0.4.79, the assignment Save button is for notebook +
        // metadata + (re-)validation only.  The test suite itself is
        // edited live via the per-script and PUT /suite endpoints, so we
        // intentionally ignore `suiteFiles`/`suiteConfig` if they arrive
        // and refuse to rebuild the zip from them.  That lets legacy
        // clients roundtrip safely while clients built against the new
        // endpoint skip the fields entirely.
        _ = uploadedSuiteFiles
        _ = suiteConfigRaw

        guard try setupHasAnyTestEntries(manifestJSON: setup.manifest) else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Add%20at%20least%20one%20test%20script%20or%20pattern%20family%20in%20the%20suite%20list%20before%20saving"
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

        setup.notebookPath = notebookPath
        try await setup.save(on: req.db)

        let activeTestSuiteScripts: Set<String> = {
            guard let data = setup.manifest.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data)
            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: setup.id!,
            testSuiteScripts: activeTestSuiteScripts,
            testSetupsDirectory: req.application.testSetupsDirectory
        )

        assignment.title = title
        assignment.dueAt = due
        assignment.deadlineOverrideActive = normalizedDeadlineOverrideAfterDueDateChange(
            dueAt: due,
            existingOverride: assignment.deadlineOverrideActive ?? false
        )
        assignment.isOpen = false

        // Pre-check that a compatible runner is up before enqueueing the
        // validation submission.  Without this, the save flips
        // `validationStatus = "pending"` and the validation row sits in
        // queue indefinitely if no runner can grade it (no compatible
        // language, runner stopped, autostart disabled).  Mirrors the
        // create-assignment path's behaviour at AssignmentRoutes.swift,
        // but allows the save itself to proceed since the instructor's
        // notebook + metadata edits should still persist.
        let requirementSpec = try await loadAssignmentRequirementSpec(
            assignment: assignment,
            on: req.db
        )
        let hasEligibleRunner = try await ensureCompatibleValidationRunnerAvailability(
            req: req,
            requirements: requirementSpec
        )
        guard hasEligibleRunner else {
            assignment.validationStatus = "no-runner"
            assignment.validationSubmissionID = nil
            try await assignment.save(on: req.db)
            return req.redirect(to: "/instructor")
        }

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

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw Abort(.conflict,
                reason: "'\(filename)' is generated from pattern family '\(familyID)'. Edit the family rather than the generated script.")
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
        // v0.4.105: allow 0-mark tests (e.g. function-existence guards
        // that exist purely to short-circuit downstream tests, not to
        // contribute to the grade).  Negative values still clamp to 0.
        let points     = max(0, body.points ?? 1)
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
        } else {
            // Support files (tier=="support") aren't entries in `testSuites`,
            // but they still need to land in the shared extraction dir so
            // student JupyterLite working copies pick them up via the symlinks
            // created in `createSupportFileSymlinks`.  v0.4.116+: keep the
            // shared dir in sync after every POST /scripts upload, not just
            // the bigger /edit/save flow.
            let activeTestSuiteScripts: Set<String> = {
                guard let data = setup.manifest.data(using: .utf8),
                      let props = try? JSONDecoder().decode(TestProperties.self, from: data)
                else { return [] }
                return Set(props.testSuites.map(\.script))
            }()
            extractSupportFilesToSharedDirectory(
                zipPath: setup.zipPath,
                setupID: setup.id!,
                testSuiteScripts: activeTestSuiteScripts,
                testSetupsDirectory: req.application.testSetupsDirectory
            )
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

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw Abort(.conflict,
                reason: "'\(filename)' is generated from pattern family '\(familyID)'. Remove it via the family editor (delete the case, or delete the whole family).")
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

        // Re-extract support files to the shared dir (parallels the
        // create-script path).  Idempotent and cheap; the shared dir
        // is just a flat extraction of every non-test, non-notebook
        // entry in the zip, so a deleted file vanishes from there too.
        let activeTestSuiteScripts: Set<String> = {
            guard let data = setup.manifest.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data)
            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: setup.id!,
            testSuiteScripts: activeTestSuiteScripts,
            testSetupsDirectory: req.application.testSetupsDirectory
        )
        return .noContent
    }

    // MARK: - GET /instructor/new/draft/solution-notebook
    //
    // Returns the draft solution notebook JSON so the scan-for-functions flow
    // works after an upload round-trip (file input is empty on reload).

    @Sendable
    func draftSolutionNotebook(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor, let userID = user.id else { throw Abort(.forbidden) }

        guard let draftID = try? req.query.get(String.self, at: "draftID"),
              !draftID.isEmpty,
              let setup = try await APITestSetup.find(draftID, on: req.db)
        else { throw Abort(.notFound) }

        let fallbackPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
        guard let data = draftNotebookData(
            req: req, setupID: setup.id!, userID: userID,
            fileKind: .solution, fallbackPath: fallbackPath)
        else { throw Abort(.notFound) }

        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
    }

    // MARK: - GET /instructor/script-templates
    //
    // Returns a JSON dict of generic (non-function-specific) script templates
    // keyed by the same identifiers used in the template <select> dropdown.

    @Sendable
    func getScriptTemplates(req: Request) async throws -> Response {
        var templates: [String: String] = [:]
        for type in PythonTestTemplateType.allCases {
            templates["py:\(type.rawValue)"] = pythonTestScript(type: type)
        }
        for type in ShellTestTemplateType.allCases {
            templates["sh:\(type.rawValue)"] = shellTestScript(type: type)
        }
        return try await templates.encodeResponse(for: req)
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

        // v0.4.111: switched from `scanNotebookForFunctions` to the
        // section-aware variant so each function carries the `## `
        // header it was defined under.  The family editor uses
        // `sectionName` to filter the dropdown to functions belonging
        // to the family's section — works on brand-new sections that
        // don't yet have any tests, which the filename-token filter
        // (v0.4.108–110) couldn't.
        let scan = scanNotebookForSectionsAndFunctions(notebookData)

        // Forward ALL fields the scanner produces — not just a hand-picked
        // subset.  Pre-v0.4.94 this DTO dropped `paramTypes`, `returnType`,
        // `isShadowed`, and `paramHasDefault`, so the family-editor client
        // always saw them as undefined, which made `coerceByType` fall
        // back to untyped JSON.parse — a bare `20260422` in a `str` column
        // became `int(20260422)` and the renderer emitted a generated
        // test that then failed validation.
        struct FunctionResult: Content {
            var name: String
            var paramNames: [String]
            var paramCount: Int
            var paramTypes: [String?]
            var paramHasDefault: [Bool]
            var returnType: String?
            var hasTypeHints: Bool
            var hasDocstring: Bool
            var isShadowed: Bool
            /// The `##` markdown header the function was defined under
            /// in the solution notebook.  `nil` when the function
            /// appears before any `##` header.  v0.4.111+.
            var sectionName: String?
            var templates: [TestTemplateInfo]
        }

        let results = scan.functions.map { entry in
            let fn = entry.info
            return FunctionResult(
                name: fn.name,
                paramNames: fn.paramNames,
                paramCount: fn.paramCount,
                paramTypes: fn.paramTypes,
                paramHasDefault: fn.paramHasDefault,
                returnType: fn.returnType,
                hasTypeHints: fn.hasTypeHints,
                hasDocstring: fn.hasDocstring,
                isShadowed: fn.isShadowed,
                sectionName: entry.sectionName,
                templates: allTemplateInfos(functionName: fn.name, paramNames: fn.paramNames)
            )
        }

        return try await results.encodeResponse(for: req)
    }

    // MARK: - POST /instructor/:assignmentID/create-solution

    @Sendable
    func createSolutionFromAssignment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor, let userID = user.id else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let sourceData = (try? notebookData(for: setup))
            ?? defaultNotebookData(title: "\(assignment.title) Solution")
        let normalized = normalizeNotebookForJupyterLite(sourceData)

        let draftPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
        try normalized.write(to: URL(fileURLWithPath: draftPath))

        _ = try await ensureUserNotebookWorkingCopy(
            req: req, setupID: setup.id!, userID: userID, fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: setup.id!, userID: userID, fileKind: .solution),
            overwriteWith: normalized)

        return req.redirect(to: "/testsetups/\(setup.id!)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))")
    }
}

// MARK: - Route parameter helpers

/// Extracts and validates the `:filename` route parameter.
/// Rejects any value that contains path separators or traversal components.
/// File-internal (not private) so AssignmentRoutes+Draft.swift can reuse
/// the same sanitisation for its draft-scoped `delete` handler.
func safeScriptFilename(from req: Request) throws -> String {
    guard let raw = req.parameters.get("filename"), !raw.isEmpty else {
        throw Abort(.badRequest, reason: "Missing filename parameter")
    }
    let cleaned = (raw as NSString).lastPathComponent
    guard cleaned == raw, !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
        throw Abort(.badRequest, reason: "Invalid filename '\(raw)'")
    }
    return cleaned
}

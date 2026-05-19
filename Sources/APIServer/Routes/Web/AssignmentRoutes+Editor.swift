// APIServer/Routes/Web/AssignmentRoutes+Editor.swift
//
// Instructor assignment editor routes: file downloads, edit/save, script
// CRUD, and notebook scanning. All routes registered in AssignmentRoutes.boot().

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
    // MARK: - GET /instructor/:assignmentID/files/notebook

    @Sendable
    func downloadCurrentNotebookFile(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
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
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        struct FileQuery: Content {
            let name: String
        }
        let q = try req.query.decode(FileQuery.self)
        let fileName = (q.name as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName == q.name else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Invalid file name")
        }

        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: fileName) else {
            throw WebAssignmentError.notFound(resource: "File '\(fileName)' in setup")
        }
        return buildFileResponse(data: data, filename: fileName)
    }

    // MARK: - GET /instructor/:assignmentID/files/solution

    @Sendable
    func downloadCurrentSolutionFile(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        // Look for a solution.* entry inside the test setup zip.
        let solutionZipEntry = listZipEntries(zipPath: setup.zipPath)
            .first(where: { $0.hasPrefix("solution.") })
        if let entryName = solutionZipEntry,
            let data = extractZipEntry(zipPath: setup.zipPath, entryName: entryName)
        {
            return buildFileResponse(data: data, filename: entryName)
        }

        // Fall back to the most recent validation submission, preserving
        // the instructor's original filename (e.g. bmi.py, dna.py).
        if let validationID = assignment.validationSubmissionID,
            let validationSubmission = try await APISubmission.find(validationID, on: req.db),
            let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
            !data.isEmpty
        {
            return buildFileResponse(data: data, filename: validationSubmission.filename ?? "solution.ipynb")
        }

        if let fallbackSubmission = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first(),
            let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
            !data.isEmpty
        {
            return buildFileResponse(data: data, filename: fallbackSubmission.filename ?? "solution.ipynb")
        }

        throw WebAssignmentError.notFound(resource: "Solution notebook for this assignment")
    }

    // MARK: - POST /instructor/:assignmentID/edit/save

    @Sendable
    func saveEditedAssignment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        let form = try parseSaveEditedAssignmentForm(req: req)

        let title = (form.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(form.dueAtRaw)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(form.dueAtRaw ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        // As of v0.4.79, the assignment Save button is for notebook +
        // metadata + (re-)validation only.  The test suite itself is
        // edited live via the per-script and PUT /suite endpoints, so we
        // intentionally ignore `suiteFiles`/`suiteConfig` if they arrive
        // and refuse to rebuild the zip from them.  That lets legacy
        // clients roundtrip safely while clients built against the new
        // endpoint skip the fields entirely.

        let hasUploadedAssignmentNotebook = form.assignmentNotebookFile?.data.readableBytes ?? 0 > 0
        let assignmentNotebookRaw = resolvedAssignmentNotebookRaw(
            uploaded: form.assignmentNotebookFile,
            hasUpload: hasUploadedAssignmentNotebook,
            setup: setup
        )
        guard !assignmentNotebookRaw.isEmpty,
            (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil
        else {
            let q =
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required%20and%20must%20be%20valid%20JSON"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        let resolved = try await resolveSolutionForEditedAssignment(
            req: req,
            user: user,
            assignment: assignment,
            setup: setup,
            uploadedSolution: form.solutionNotebookFile
        )
        guard !resolved.data.isEmpty else {
            let q =
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required%20for%20validation"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        guard try setupHasAnyTestEntries(manifestJSON: setup.manifest) else {
            let q =
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))&error=Add%20at%20least%20one%20test%20script%20or%20pattern%20family%20in%20the%20suite%20list%20before%20saving"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        try persistAssignmentNotebook(
            req: req,
            assignment: assignment,
            setup: setup,
            assignmentNotebookRaw: assignmentNotebookRaw,
            uploadedFile: form.assignmentNotebookFile,
            hasUpload: hasUploadedAssignmentNotebook
        )
        try await setup.save(on: req.db)

        extractSupportFilesForActiveSuite(
            req: req,
            setup: setup,
            assignmentTestSetupID: assignment.testSetupID
        )

        assignment.title = title
        assignment.dueAt = due
        assignment.deadlineOverrideActive = normalizedDeadlineOverrideAfterDueDateChange(
            dueAt: due,
            existingOverride: assignment.deadlineOverrideActive ?? false
        )
        assignment.isOpen = false

        return try await enqueueValidationForEditedAssignment(
            req: req,
            assignment: assignment,
            solution: resolved
        )
    }

    // MARK: - saveEditedAssignment helpers

    /// Parsed form payload for `POST /instructor/:assignmentID/edit/save`.
    /// Resolves both the array-typed (`suiteFiles[]`) and single-typed
    /// (`suiteFiles`) Vapor decode paths into one shape.
    fileprivate struct SaveEditedAssignmentForm {
        let assignmentName: String?
        let dueAtRaw: String?
        let assignmentNotebookFile: File?
        let solutionNotebookFile: File?
    }

    fileprivate struct ResolvedSolution {
        let data: Data
        let filename: String
        let isNotebook: Bool
    }

    fileprivate func parseSaveEditedAssignmentForm(req: Request) throws -> SaveEditedAssignmentForm {
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
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Invalid assignment upload payload")
        }

        let assignmentName =
            try multipartTextField(named: ["assignmentName"], from: req)
            ?? bodyMany?.assignmentName
            ?? bodySingle?.assignmentName
        let dueAtRaw =
            try multipartTextField(named: ["dueAt"], from: req)
            ?? bodyMany?.dueAt
            ?? bodySingle?.dueAt
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile

        return SaveEditedAssignmentForm(
            assignmentName: assignmentName,
            dueAtRaw: dueAtRaw,
            assignmentNotebookFile: assignmentNotebookFile,
            solutionNotebookFile: solutionNotebookFile
        )
    }

    /// Marmoset-style worker-mode imports often have no starter .ipynb.
    /// Falls back to an empty notebook so the edit can proceed without
    /// requiring the instructor to upload one on every save.
    fileprivate func resolvedAssignmentNotebookRaw(
        uploaded: File?,
        hasUpload: Bool,
        setup: APITestSetup
    ) -> Data {
        guard let uploaded, hasUpload else {
            return (try? notebookData(for: setup)) ?? minimalEmptyNotebookData()
        }
        return Data(uploaded.data.readableBytesView)
    }

    /// Resolves solution data + filename: prefer uploaded file, then zip
    /// entry, then prior validation submission, then draft notebook.
    fileprivate func resolveSolutionForEditedAssignment(
        req: Request,
        user: APIUser,
        assignment: APIAssignment,
        setup: APITestSetup,
        uploadedSolution: File?
    ) async throws -> ResolvedSolution {
        var solutionFilename = "solution.ipynb"
        let solutionNotebookRaw: Data = {
            if let uploadedSolution, uploadedSolution.data.readableBytes > 0 {
                solutionFilename = submissionFilenameForStorage(
                    uploadedName: uploadedSolution.filename,
                    fallback: "solution.ipynb"
                )
                return Data(uploadedSolution.data.readableBytesView)
            }
            let archiveFiles = listZipEntries(zipPath: setup.zipPath)
            if let solutionEntry = archiveFiles.first(where: { $0.hasPrefix("solution.") }),
                let data = extractZipEntry(zipPath: setup.zipPath, entryName: solutionEntry)
            {
                solutionFilename = solutionEntry
                return data
            }
            return Data()
        }()
        var resolvedSolutionNotebookRaw = solutionNotebookRaw
        if resolvedSolutionNotebookRaw.isEmpty,
            let existingSolution = try await loadExistingSolution(req: req, assignment: assignment)
        {
            resolvedSolutionNotebookRaw = existingSolution.data
            solutionFilename = existingSolution.filename
        }
        if resolvedSolutionNotebookRaw.isEmpty, let userID = user.id,
            let draftData = draftNotebookData(
                req: req, setupID: assignment.testSetupID, userID: userID, fileKind: .solution,
                fallbackPath: draftSolutionNotebookPath(
                    testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID))
        {
            resolvedSolutionNotebookRaw = draftData
        }
        let isNotebook = (try? JSONSerialization.jsonObject(with: resolvedSolutionNotebookRaw)) != nil
        return ResolvedSolution(
            data: resolvedSolutionNotebookRaw,
            filename: solutionFilename,
            isNotebook: isNotebook
        )
    }

    /// Normalises the assignment notebook bytes and writes them to disk,
    /// updating `setup.notebookPath` to point at the new location.
    fileprivate func persistAssignmentNotebook(
        req: Request,
        assignment: APIAssignment,
        setup: APITestSetup,
        assignmentNotebookRaw: Data,
        uploadedFile: File?,
        hasUpload: Bool
    ) throws {
        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)
        let notebookPath: String = {
            if hasUpload {
                let fallbackName =
                    setup.notebookPath
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? "assignment.ipynb"
                let uploadedName = uploadedFile?.filename
                let filename = notebookFilenameForStorage(uploadedName: uploadedName, fallback: fallbackName)
                let dir = req.application.testSetupsDirectory + "notebooks/\(assignment.testSetupID)/"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                return dir + filename
            }
            return setup.notebookPath ?? (req.application.testSetupsDirectory + "\(assignment.testSetupID).ipynb")
        }()
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        setup.notebookPath = notebookPath
    }

    /// Refreshes the shared support-files directory after an assignment
    /// save so student JupyterLite working copies pick up changes.
    fileprivate func extractSupportFilesForActiveSuite(
        req: Request,
        setup: APITestSetup,
        assignmentTestSetupID: String
    ) {
        let activeTestSuiteScripts: Set<String> = {
            guard let data = setup.manifest.data(using: .utf8),
                let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: assignmentTestSetupID,
            testSuiteScripts: activeTestSuiteScripts,
            testSetupsDirectory: req.application.testSetupsDirectory
        )
    }

    /// Pre-checks runner availability, enqueues the validation submission
    /// (or marks `no-runner` if no compatible runner is up), persists the
    /// assignment, and returns the redirect.
    fileprivate func enqueueValidationForEditedAssignment(
        req: Request,
        assignment: APIAssignment,
        solution: ResolvedSolution
    ) async throws -> Response {
        // Pre-check that a compatible runner is up before enqueueing the
        // validation submission.  Without this, the save flips
        // `validationStatus = "pending"` and the validation row sits in
        // queue indefinitely if no runner can grade it (no compatible
        // language, runner stopped, autostart disabled).
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
        let solutionDataToSubmit =
            solution.isNotebook
            ? normalizeNotebookForJupyterLite(solution.data)
            : solution.data
        let validationSubmissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: assignment.testSetupID,
            solutionNotebookData: solutionDataToSubmit,
            filename: solution.filename
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
        let idStr = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }

        guard let content = readScriptFromZip(zipPath: setup.zipPath, filename: filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
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
        let idStr = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        struct UpdateBody: Content { var content: String }
        let body = try req.content.decode(UpdateBody.self)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }

        // Verify the file exists before writing.
        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
        }

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw WebAssignmentError.conflict(
                reason:
                    "'\(filename)' is generated from pattern family '\(familyID)'. Edit the family rather than the generated script."
            )
        }

        // Slice 1: inline global + section variables before write so the
        // saved script content matches what the runner will see.  Falls
        // back to raw content for non-.py files or when manifest decode
        // fails (degrades to pre-Slice-1 behaviour).
        let inlinedContent: String = {
            guard let data = setup.manifest.data(using: .utf8),
                let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return body.content }
            return TestScriptVariablePrepender.applyForRawScript(
                filename: filename,
                content: body.content,
                manifest: manifest
            )
        }()

        do {
            try updateScriptInZip(zipPath: setup.zipPath, filename: filename, content: inlinedContent)
        } catch ScriptZipError.zipFailed {
            throw WebAssignmentError.internalFailure(reason: "Failed to update setup zip")
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
        let idStr = try assignmentPublicIDParameter(from: req)

        struct CreateBody: Content {
            var filename: String
            var content: String
            var tier: String?
            var points: Int?
            var isTest: Bool?
        }
        let body = try req.content.decode(CreateBody.self)

        // Validate filename: must be a simple filename (no path separators).
        let cleaned = sanitizeSuiteFilename(body.filename)
        guard !cleaned.isEmpty, cleaned == body.filename else {
            throw WebAssignmentError.invalidParameter(name: "filename", reason: "Invalid filename '\(body.filename)'")
        }

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }

        // Reject duplicate filenames.
        if listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
            throw WebAssignmentError.conflict(reason: "A file named '\(cleaned)' already exists in this setup")
        }

        // Slice 1: prepend assignment-scope variables.  Section variables
        // aren't applied here (the suite entry — and thus its sectionID —
        // is created below); the next applyPatternFamilies / suite-edit
        // save will re-prepend with the correct section scope.
        let createInlined: String = {
            guard let data = setup.manifest.data(using: .utf8),
                let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return body.content }
            return TestScriptVariablePrepender.applyForRawScript(
                filename: cleaned,
                content: body.content,
                manifest: manifest
            )
        }()
        try updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: createInlined)

        let tier = normalizeTier(body.tier, isTest: body.isTest)
        // v0.4.105: allow 0-mark tests (e.g. function-existence guards
        // that exist purely to short-circuit downstream tests, not to
        // contribute to the grade).  Negative values still clamp to 0.
        let points = max(0, body.points ?? 1)
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
                    let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
                else { return [] }
                return Set(props.testSuites.map(\.script))
            }()
            extractSupportFilesToSharedDirectory(
                zipPath: setup.zipPath,
                setupID: assignment.testSetupID,
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
        let idStr = try assignmentPublicIDParameter(from: req)
        let filename = try safeScriptFilename(from: req)

        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }

        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
        }

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw WebAssignmentError.conflict(
                reason:
                    "'\(filename)' is generated from pattern family '\(familyID)'. Remove it via the family editor (delete the case, or delete the whole family)."
            )
        }

        let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
        guard dependents.isEmpty else {
            throw WebAssignmentError.conflict(
                reason:
                    "Cannot delete '\(filename)': the following scripts depend on it: \(dependents.joined(separator: ", "))"
            )
        }

        do {
            try removeScriptFromZip(zipPath: setup.zipPath, filename: filename)
        } catch ScriptZipError.zipFailed {
            throw WebAssignmentError.internalFailure(reason: "Failed to update setup zip")
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
                let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: assignment.testSetupID,
            testSuiteScripts: activeTestSuiteScripts,
            testSetupsDirectory: req.application.testSetupsDirectory
        )
        return .noContent
    }

    // `draftSolutionNotebook` moved to `AssignmentRoutes+Draft.swift` in
    // v0.4.177 (it serves a `/instructor/new/draft/...` URL and now lives
    // on `DraftAssignmentRoutes`).

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
        guard let buffer = req.body.data else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Request body is empty")
        }
        let notebookData = Data(buffer.readableBytesView)
        guard !notebookData.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Notebook data is empty")
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
        guard let userID = user.id else {
            throw WebAssignmentError.internalFailure(reason: "Authenticated user has no ID")
        }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }

        let sourceData =
            (try? notebookData(for: setup))
            ?? defaultNotebookData(title: "\(assignment.title) Solution")
        let normalized = normalizeNotebookForJupyterLite(sourceData)

        let draftPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        try normalized.write(to: URL(fileURLWithPath: draftPath))

        _ = try await ensureUserNotebookWorkingCopy(
            req: req, setupID: assignment.testSetupID, userID: userID, fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: assignment.testSetupID, userID: userID, fileKind: .solution),
            overwriteWith: normalized)

        return req.redirect(
            to: "/testsetups/\(assignment.testSetupID)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))")
    }
}

// MARK: - Route parameter helpers

/// Extracts and validates the `:filename` route parameter.
/// Rejects any value that contains path separators or traversal components.
/// File-internal (not private) so AssignmentRoutes+Draft.swift can reuse
/// the same sanitisation for its draft-scoped `delete` handler.
func safeScriptFilename(from req: Request) throws -> String {
    guard let raw = req.parameters.get("filename"), !raw.isEmpty else {
        throw WebAssignmentError.invalidParameter(name: "filename", reason: "Missing filename parameter")
    }
    let cleaned = (raw as NSString).lastPathComponent
    guard cleaned == raw, !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
        throw WebAssignmentError.invalidParameter(name: "filename", reason: "Invalid filename '\(raw)'")
    }
    return cleaned
}

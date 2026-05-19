// APIServer/Routes/Web/PublishedAssignmentRoutes+SaveEdit.swift
//
// `POST /instructor/:assignmentID/edit/save` plus its file-private
// helpers.  Split out of `AssignmentRoutes+Editor.swift` in v0.4.183
// (Phase 4.2 of the audit-driven refactor).  No behaviour change.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
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
            guard let props = setup.decodedManifest()

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
}

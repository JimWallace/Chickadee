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

        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let idStr = assignment.publicID

        let form = try parseSaveEditedAssignmentForm(req: req)

        let title = (form.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(form.dueAtRaw)
        let starts = parseDueDate(form.startsAtRaw)
        let startsAtQuery = "&startsAt=\(urlEncode(form.startsAtRaw ?? ""))"

        guard !title.isEmpty else {
            let q =
                "assignmentName=&dueAt=\(urlEncode(form.dueAtRaw ?? ""))\(startsAtQuery)&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        // As of v0.4.79, the assignment Save button is for notebook +
        // metadata + (re-)validation only.  The test suite itself is
        // edited live via the per-script and PUT /suite endpoints; the
        // save form carries no suite fields (a stale client that still
        // posts `suiteFiles`/`suiteConfig` parts is harmless — the form
        // decoder ignores parts it isn't asked for).

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
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))\(startsAtQuery)&error=Assignment%20notebook%20(.ipynb)%20is%20required%20and%20must%20be%20valid%20JSON"
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
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))\(startsAtQuery)&error=Solution%20notebook%20(.ipynb)%20is%20required%20for%20validation"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        guard try setupHasAnyTestEntries(manifestJSON: setup.manifest) else {
            let q =
                "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))\(startsAtQuery)&error=Add%20at%20least%20one%20test%20script%20or%20pattern%20family%20in%20the%20suite%20list%20before%20saving"
            return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
        }

        // Persist a changed submission mode before anything else touches the
        // row: `setManifestSubmissionMode` refuses the upload + browser
        // combination, and refusing must leave the assignment entirely
        // unmodified — not half-saved.
        if let requestedMode = form.submissionMode,
            requestedMode == SubmissionMode.notebook.rawValue
                || requestedMode == SubmissionMode.uploadOnly.rawValue
        {
            do {
                _ = try await setManifestSubmissionMode(
                    setup: setup, to: requestedMode, on: req.db)
            } catch {
                let q =
                    "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(form.dueAtRaw ?? ""))\(startsAtQuery)&error=\(urlEncode(uploadModeGradingConflictMessage))"
                return req.redirect(to: "/instructor/\(idStr)/edit?\(q)")
            }
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

        let previousDueAt = assignment.dueAt
        assignment.title = title
        assignment.dueAt = due
        assignment.startsAt = starts
        assignment.deadlineOverrideActive = normalizedDeadlineOverrideAfterDueDateChange(
            dueAt: due,
            existingOverride: assignment.deadlineOverrideActive ?? false
        )
        if let rawID = form.gradeObjectID {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            assignment.brightspaceGradeObjectID = trimmed.isEmpty ? nil : trimmed
        }
        // Editing returns the assignment to closed (re-validation gates the
        // re-open / re-preview), matching the close-on-save contract.
        //
        // Except from the assignment workbench, which sets `liveEdit`.  That
        // surface writes live — `PUT /suite`, `PUT /families` and
        // `POST /notebook/save` all change content without touching visibility
        // — and closing there would mean fixing a typo pulls a lab out from
        // under the students sitting in it.  Re-validation still runs either
        // way; the only difference is whether students lose access while it
        // does.  This is a contract, not a permission: the caller already holds
        // TA+ write access to this course, checked above.
        if !form.liveEdit {
            assignment.visibility = .closed
        }

        // Only when it actually moved: the Save button posts the whole form on
        // every content edit, so auditing unconditionally would bury the real
        // deadline changes under one row per save.
        if previousDueAt != due {
            await AuditLogger.recordAssignmentLifecycle(
                .assignmentDueDateChanged, assignment: assignment,
                metadata: [
                    "previous": previousDueAt.map(ISO8601DateFormatter().string(from:)) ?? "none",
                    "current": due.map(ISO8601DateFormatter().string(from:)) ?? "none",
                ], on: req)
        }

        return try await enqueueValidationForEditedAssignment(
            req: req,
            assignment: assignment,
            solution: resolved
        )
    }

    // MARK: - saveEditedAssignment helpers

    /// Parsed form payload for `POST /instructor/:assignmentID/edit/save`.
    fileprivate struct SaveEditedAssignmentForm {
        let assignmentName: String?
        let dueAtRaw: String?
        let startsAtRaw: String?
        let assignmentNotebookFile: File?
        let solutionNotebookFile: File?
        let gradeObjectID: String?
        /// "notebook" | "uploadOnly" from the Submission select; nil when the
        /// form predates the field (a stale open tab) so the stored mode is
        /// left untouched rather than reset to the default.
        let submissionMode: String?
        /// Set by the assignment workbench's embedded form.  Suppresses the
        /// close-on-save below; see the comment at that call site.
        let liveEdit: Bool
    }

    fileprivate struct ResolvedSolution {
        let data: Data
        let filename: String
        let isNotebook: Bool
    }

    fileprivate func parseSaveEditedAssignmentForm(req: Request) throws -> SaveEditedAssignmentForm {
        struct SaveBody: Content {
            var assignmentName: String?
            var dueAt: String?
            var startsAt: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var gradeObjectID: String?
            var submissionMode: String?
            var liveEdit: String?
        }

        guard let body = try? req.content.decode(SaveBody.self) else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Invalid assignment upload payload")
        }

        // The multipartTextField fallbacks cover Safari's mixed-encoding
        // multipart bodies, where Vapor's content decode drops text fields
        // that ride alongside file parts (the v0.4.8 save hardening).
        return SaveEditedAssignmentForm(
            assignmentName: try multipartTextField(named: ["assignmentName"], from: req) ?? body.assignmentName,
            dueAtRaw: try multipartTextField(named: ["dueAt"], from: req) ?? body.dueAt,
            startsAtRaw: try multipartTextField(named: ["startsAt"], from: req) ?? body.startsAt,
            assignmentNotebookFile: body.assignmentNotebookFile,
            solutionNotebookFile: body.solutionNotebookFile,
            gradeObjectID: try multipartTextField(named: ["gradeObjectID"], from: req) ?? body.gradeObjectID,
            submissionMode: try multipartTextField(named: ["submissionMode"], from: req)
                ?? body.submissionMode,
            liveEdit: (try multipartTextField(named: ["liveEdit"], from: req) ?? body.liveEdit) != nil
        )
    }

    /// Worker-mode assignments often have no starter .ipynb.
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
            req.logger.warning(
                "Validation pre-check found no compatible active runner; marking assignment \(assignment.publicID) no-runner"
            )
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

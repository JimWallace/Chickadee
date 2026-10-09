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

        guard !title.isEmpty else {
            return redirectToEditForm(req: req, assignmentID: idStr, form: form, error: "Assignment name is required")
        }

        // The route admits a TA, because a TA edits content. The form also
        // carries fields that only an instructor may change, as on MCP and on
        // the `/close`, `/activity` and `/brightspace` routes (#2484). A TA's
        // Save that changes one is refused before anything is written.
        let isInstructor =
            try await evaluateCourseWrite(
                user: user, courseID: assignment.courseID, atLeast: .instructor, db: req.db) == nil
        if !isInstructor {
            let changed = instructorOnlyFieldsChanged(
                form: form, title: title, due: due, starts: starts,
                assignment: assignment, setup: setup)
            if !changed.isEmpty {
                throw AppError.forbidden(
                    action: "change \(changed.joined(separator: ", ")). Only an instructor can change it")
            }
        }

        // As of v0.4.79, the assignment Save button is for notebook +
        // metadata + (re-)validation only.  The test suite itself is
        // edited live via the per-script and PUT /suite endpoints; the
        // save form carries no suite fields (a stale client that still
        // posts `suiteFiles`/`suiteConfig` parts is harmless — the form
        // decoder ignores parts it isn't asked for).

        let hasUploadedAssignmentNotebook = form.assignmentNotebookFile?.data.readableBytes ?? 0 > 0
        let assignmentNotebookRaw = await resolvedAssignmentNotebookRaw(
            uploaded: form.assignmentNotebookFile,
            hasUpload: hasUploadedAssignmentNotebook,
            setup: setup
        )
        guard !assignmentNotebookRaw.isEmpty,
            (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil
        else {
            return redirectToEditForm(
                req: req, assignmentID: idStr, form: form,
                error: "Assignment notebook (.ipynb) is required and must be valid JSON")
        }

        let resolved = try await resolveSolutionForEditedAssignment(
            req: req,
            user: user,
            assignment: assignment,
            setup: setup,
            uploadedSolution: form.solutionNotebookFile
        )
        guard !resolved.data.isEmpty else {
            return redirectToEditForm(
                req: req, assignmentID: idStr, form: form,
                error: "Solution notebook (.ipynb) is required for validation")
        }

        guard try setupHasAnyTestEntries(manifestJSON: setup.manifest) else {
            return redirectToEditForm(
                req: req, assignmentID: idStr, form: form,
                error: "Add at least one test script or pattern family in the suite list before saving")
        }

        // Persist the manifest settings before anything else touches the row:
        // each helper refuses an incoherent state, and refusing must leave the
        // assignment entirely unmodified — not half-saved.
        if let refusal = await persistManifestSettings(form: form, setup: setup, on: req.db) {
            return redirectToEditForm(req: req, assignmentID: idStr, form: form, error: refusal)
        }

        try await persistAssignmentNotebook(
            req: req,
            assignment: assignment,
            setup: setup,
            assignmentNotebookRaw: assignmentNotebookRaw,
            uploadedFile: form.assignmentNotebookFile,
            hasUpload: hasUploadedAssignmentNotebook
        )
        try await setup.save(on: req.db)

        await extractSupportFilesForActiveSuite(
            req: req,
            setup: setup,
            assignmentTestSetupID: assignment.testSetupID
        )

        let previousDueAt = assignment.dueAt
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
        //
        // A TA's Save never closes: the close is an instructor action (#2484),
        // so a TA's Save writes live, as the workbench does.
        // The same write the MCP update tool makes, so the two cannot drift
        // on how a due-date change re-normalises the deadline override. It
        // saves the row, with the fields set above, and audits the close.
        try await AssignmentAuthoringService.updateMetadata(
            assignment,
            title: title,
            dueAt: due.map { .set($0) } ?? .clear,
            startsAt: starts.map { .set($0) } ?? .clear,
            open: !form.liveEdit && isInstructor ? false : nil,
            audit: .web(req, reason: "save"),
            on: req.db)

        // Only when it actually moved: the Save button posts the whole form on
        // every content edit, so auditing unconditionally would bury the real
        // deadline changes under one row per save.
        if previousDueAt != due {
            await AuditLogger.recordAssignmentLifecycle(
                .assignmentDueDateChanged, assignment: assignment,
                metadata: [
                    "previous": previousDueAt.map(iso8601String) ?? "none",
                    "current": due.map(iso8601String) ?? "none",
                ], on: req)
        }

        return try await enqueueValidationForEditedAssignment(
            req: req,
            assignment: assignment,
            solution: resolved
        )
    }

    // MARK: - saveEditedAssignment helpers

    /// The instructor-only fields that this Save would change, named for the
    /// refusal. Empty when the Save changes content only.
    ///
    /// Each field is compared as the form shows it. Dates compare at the
    /// minute, because the form shows the minute, so a date that MCP stored
    /// with seconds is not a change.
    fileprivate func instructorOnlyFieldsChanged(
        form: SaveEditedAssignmentForm, title: String, due: Date?, starts: Date?,
        assignment: APIAssignment, setup: APITestSetup
    ) -> [String] {
        var changed: [String] = []
        if title != assignment.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            changed.append("the title")
        }
        if dueAtLocalInputString(due) != dueAtLocalInputString(assignment.dueAt) {
            changed.append("the due date")
        }
        if dueAtLocalInputString(starts) != dueAtLocalInputString(assignment.startsAt) {
            changed.append("the open date")
        }
        if let rawID = form.gradeObjectID {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.isEmpty ? nil : trimmed) != assignment.brightspaceGradeObjectID {
                changed.append("the LEARN assessment")
            }
        }
        if let mode = form.submissionMode.flatMap(SubmissionMode.init(rawValue:)),
            mode.rawValue != currentManifestSubmissionMode(setup.manifest)
        {
            changed.append("the submission method")
        }
        // `try?` would flatten "none" (a nil language) into "not parsed".
        if let requested = form.assignmentLanguage,
            !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            case .success(let parsed) = Result(catching: { try parseLanguageChoice(requested) }),
            parsed?.rawValue != currentManifestLanguage(setup.manifest)
        {
            changed.append("the language")
        }
        if requestedActivityChange(form.activityKind, current: currentManifestActivity(setup.manifest)) != nil {
            changed.append("the class activity")
        }
        return changed
    }

    /// Returns the author to the edit form with what they typed and one
    /// error, the way every refusal in `saveEditedAssignment` does. The name
    /// is sent back trimmed, so a blank name posts back as blank.
    fileprivate func redirectToEditForm(
        req: Request, assignmentID: String, form: SaveEditedAssignmentForm, error: String
    ) -> Response {
        let title = (form.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query =
            "assignmentName=\(urlEncode(title))"
            + "&dueAt=\(urlEncode(form.dueAtRaw ?? ""))"
            + "&startsAt=\(urlEncode(form.startsAtRaw ?? ""))"
            + "&error=\(urlEncode(error))"
        return req.redirect(to: "/instructor/\(assignmentID)/edit?\(query)")
    }

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
        /// An `AssignmentLanguage` raw value from the Language select, "" for
        /// "detect automatically", or nil when the form predates the field (a
        /// stale open tab) so the stored language is left untouched.  The empty
        /// string and nil mean different things here and must stay distinct:
        /// one clears a declaration, the other is silence.
        let assignmentLanguage: String?
        /// An `ActivityKind` raw value or "none" from the Class activity
        /// select, or nil when the form carried no such field — a stale tab,
        /// or the select rendered disabled because the kind is locked (a
        /// disabled control is not submitted), which leaves the stored block
        /// untouched rather than clearing it.
        let activityKind: String?
        /// Set by the assignment workbench's embedded form.  Suppresses the
        /// close-on-save below; see the comment at that call site.
        let liveEdit: Bool
    }

    fileprivate struct ResolvedSolution {
        let data: Data
        let filename: String
        let isNotebook: Bool
    }

    /// Applies the three manifest selects in order, returning the first
    /// refusal or nil. The mode goes first and the language after it, because
    /// an upload-only language sets the mode itself and must not be undone by
    /// the select that posted the old one. The activity kind comes last and is
    /// locked once a student has submitted.
    fileprivate func persistManifestSettings(
        form: SaveEditedAssignmentForm, setup: APITestSetup, on db: any Database
    ) async -> String? {
        if let refusal = await persistSubmissionMode(requested: form.submissionMode, setup: setup, on: db) {
            return refusal
        }
        if let refusal = await persistDeclaredLanguage(requested: form.assignmentLanguage, setup: setup, on: db) {
            return refusal
        }
        return await persistActivityKind(requested: form.activityKind, setup: setup, on: db)
    }

    /// Applies the Submission select's value to the manifest, returning a
    /// user-facing refusal reason or nil when it succeeded or there was nothing
    /// to do.
    ///
    /// An unrecognised value is ignored rather than refused, which is what keeps
    /// a stale tab posting a mode this build no longer has from failing the
    /// whole save. The refusal it CAN produce has one cause — the upload +
    /// browser combination — hence the single fixed message, unlike the language
    /// helper below.
    fileprivate func persistSubmissionMode(
        requested: String?, setup: APITestSetup, on db: any Database
    ) async -> String? {
        guard let requested,
            requested == SubmissionMode.notebook.rawValue
                || requested == SubmissionMode.uploadOnly.rawValue
        else { return nil }
        do {
            _ = try await setManifestSubmissionMode(setup: setup, to: requested, on: db)
            return nil
        } catch {
            // The reason `ManifestCoherence` gives: it has more than one rule
            // that a mode change can break (#2484).
            return (error as? any AbortError)?.reason ?? uploadModeGradingConflictMessage
        }
    }

    /// Applies the Language select's value to the manifest, returning a
    /// user-facing refusal reason or nil when it succeeded or there was nothing
    /// to do.
    ///
    /// `requested` nil means the field was absent — a form posted from a tab
    /// opened before it existed — and leaves the declaration alone. Anything
    /// else is an answer, including `noLanguageChoice` ("none"), which declares
    /// the assignment has no language rather than asking for one to be detected.
    ///
    /// The reason is the thrown error's own, not one fixed message: an unknown
    /// language and a change once generated tests exist are distinct refusals,
    /// and which one applies is what the author needs in order to act.
    fileprivate func persistDeclaredLanguage(
        requested: String?, setup: APITestSetup, on db: any Database
    ) async -> String? {
        guard let requested,
            !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        do {
            let language = try parseLanguageChoice(requested)
            try await changeDeclaredLanguage(setup: setup, to: language, on: db)
            return nil
        } catch {
            // `any AbortError` rather than `AppError`, so a Vapor `Abort` thrown
            // deeper in the manifest write surfaces its reason too.
            return (error as? any AbortError)?.reason
                ?? "Could not set the assignment language."
        }
    }

    /// Applies the Class activity select's value (`requestedActivityChange`),
    /// returning a user-facing refusal or nil.
    fileprivate func persistActivityKind(
        requested: String?, setup: APITestSetup, on db: any Database
    ) async -> String? {
        guard
            let change = requestedActivityChange(
                requested, current: currentManifestActivity(setup.manifest))
        else { return nil }
        do {
            try await ActivityAuthoring.setActivity(setup: setup, to: change.next, on: db)
            return nil
        } catch {
            return (error as? any AbortError)?.reason ?? "Could not set the class activity."
        }
    }

    /// The activity that the Class activity select asks for.
    fileprivate struct ActivityChange {
        let next: ClassActivity?
    }

    /// Reads the Class activity select's value. Returns nil when it asks for no
    /// change: nil `requested` is silence (see the form field), and an
    /// unrecognised value (a stale tab posting a kind this build no longer has)
    /// is ignored, as the submission-mode helper does. "none" clears. A kind
    /// token keeps the stored leaderboard visibility and opponent file when the
    /// kind is unchanged, so a Save does not un-publish a leaderboard or drop
    /// the bot.
    fileprivate func requestedActivityChange(_ requested: String?, current: ClassActivity?) -> ActivityChange? {
        guard let requested else { return nil }
        let token = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: ClassActivity?
        if token == SetActivityTool.noActivityChoice {
            next = nil
        } else if let kind = ActivityKind(rawValue: token) {
            next = current?.kind == kind ? current : ClassActivity(kind: kind)
        } else {
            return nil
        }
        return next == current ? nil : ActivityChange(next: next)
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
            var assignmentLanguage: String?
            var activityKind: String?
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
            assignmentLanguage: try multipartTextField(named: ["assignmentLanguage"], from: req)
                ?? body.assignmentLanguage,
            activityKind: try multipartTextField(named: ["activityKind"], from: req)
                ?? body.activityKind,
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
    ) async -> Data {
        guard let uploaded, hasUpload else {
            return await (try? notebookData(for: setup)) ?? minimalEmptyNotebookData()
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
        // Straight-line rather than an immediately-invoked closure: reading the
        // zip suspends now, and an async closure cannot write `solutionFilename`
        // in the enclosing scope.
        var solutionNotebookRaw = Data()
        if let uploadedSolution, uploadedSolution.data.readableBytes > 0 {
            solutionFilename = submissionFilenameForStorage(
                uploadedName: uploadedSolution.filename,
                fallback: "solution.ipynb"
            )
            solutionNotebookRaw = Data(uploadedSolution.data.readableBytesView)
        } else {
            let archiveFiles = await listZipEntries(zipPath: setup.zipPath)
            if let solutionEntry = archiveFiles.first(where: { $0.hasPrefix("solution.") }),
                let data = await extractZipEntry(zipPath: setup.zipPath, entryName: solutionEntry)
            {
                solutionFilename = solutionEntry
                solutionNotebookRaw = data
            }
        }
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
    ) async throws {
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
        try await req.fileio.writeFile(.init(data: assignmentNotebook), at: notebookPath)
        setup.notebookPath = notebookPath
    }

    /// Refreshes the shared support-files directory after an assignment
    /// save so student JupyterLite working copies pick up changes.
    fileprivate func extractSupportFilesForActiveSuite(
        req: Request,
        setup: APITestSetup,
        assignmentTestSetupID: String
    ) async {
        let activeTestSuiteScripts: Set<String> = {
            guard let props = setup.decodedManifest()

            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        await extractSupportFilesToSharedDirectory(
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
            context: req,
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
            context: req,
            setupID: assignment.testSetupID,
            solutionNotebookData: solutionDataToSubmit,
            filename: solution.filename
        )
        assignment.validationSubmissionID = validationSubmissionID
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor")
    }
}

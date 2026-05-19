// APIServer/Routes/Web/DraftAssignmentRoutes+NewAssignment.swift
//
// New-assignment creation flow: render the form, persist drafts,
// finalize-and-save a draft, and the legacy /POST /instructor
// publish handler that creates a draft assignment from an existing
// test setup.  Split from AssignmentRoutes.swift for navigability.

import Core
import Fluent
import Foundation
import Vapor

extension DraftAssignmentRoutes {
    // MARK: - GET /instructor/new

    @Sendable
    func newAssignmentPage(req: Request) async throws -> View {
        struct NewQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
            var sectionID: String?
            var draftID: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.forbidden(action: "open the new-assignment page")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        let q = (try? req.query.decode(NewQuery.self))

        let sections = try await loadNewAssignmentSectionPicker(
            req: req,
            activeCourseUUID: courseState.activeCourseUUID
        )

        let draftID = (q?.draftID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let setup = draftID.isEmpty ? nil : try await APITestSetup.find(draftID, on: req.db)
        let storedState =
            setup == nil ? NewAssignmentDraftFormState.empty : loadDraftFormState(req: req, draftID: draftID)

        let assignmentNotebook = newAssignmentNotebookContext(setup: setup, storedState: storedState)
        let solutionNotebook = newAssignmentSolutionNotebookContext(
            req: req,
            userID: userID,
            setup: setup,
            storedState: storedState
        )

        let suiteRows = setup.map(editableSuiteRowsForSetup) ?? []
        let supportFileRows = newAssignmentSupportFileRows(setup: setup, suiteRows: suiteRows)
        let detected = newAssignmentRequirementSuggestions(req: req, userID: userID, setup: setup)

        let assignmentName = (q?.assignmentName ?? storedState.assignmentName).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let dueAt = q?.dueAt ?? storedState.dueAt
        let selectedSectionID = q?.sectionID ?? storedState.sectionID

        let ctx = NewAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentName: assignmentName,
            dueAt: dueAt,
            sections: sections,
            preselectedSectionID: selectedSectionID,
            draftID: setup?.id,
            draftIDJSON: newAssignmentDraftIDJSON(setup: setup),
            assignmentNotebook: assignmentNotebook,
            solutionNotebook: solutionNotebook,
            suiteRows: suiteRows,
            hasSuiteRows: !suiteRows.isEmpty,
            supportFileRows: supportFileRows,
            patternFamiliesJSON: newAssignmentPatternFamiliesJSON(setup: setup),
            notebookChecksJSON: newAssignmentNotebookChecksJSON(setup: setup),
            suiteStateJSON: newAssignmentSuiteStateSeedJSON(setup: setup),
            suiteSectionRows: newAssignmentSuiteSectionShellRows(setup: setup),
            requiredPlatform: storedState.requiredPlatform,
            requiredArchitecture: storedState.requiredArchitecture,
            requiredLanguagesCSV: storedState.requiredLanguagesCSV.isEmpty
                ? detected.languages.joined(separator: ", ")
                : storedState.requiredLanguagesCSV,
            requiredCapabilitiesCSV: storedState.requiredCapabilitiesCSV.isEmpty
                ? detected.capabilities.joined(separator: ", ")
                : storedState.requiredCapabilitiesCSV,
            detectedLanguages: detected.languages,
            detectedCapabilities: detected.capabilities,
            detectedLanguagesCSV: detected.languages.joined(separator: ", "),
            detectedCapabilitiesCSV: detected.capabilities.joined(separator: ", "),
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-new", ctx)
    }

    // updateNewAssignmentDraft is the dispatcher for the new-assignment
    // form's "Save draft" partial-form actions (9 verbs: create / upload
    // / clear assignment & solution notebooks, replace / clear suite
    // files, etc.).  Each verb touches file I/O, draft state, and zip
    // rebuilding in slightly different ways.
    //
    // The handler stays thin: parse → resolve setup → seed form state
    // → delegate to `NewAssignmentDraftService` → write back form
    // state → redirect.  The per-verb logic lives on the service so
    // each verb is independently navigable and unit-testable.  See
    // `Sources/APIServer/Services/NewAssignmentDraftService.swift`.
    @Sendable
    func updateNewAssignmentDraft(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.forbidden(action: "edit a new-assignment draft")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "creating an assignment")
        }

        let payload = try parseNewAssignmentDraftPayload(req: req)

        let setup = try await resolveOrCreateNewAssignmentDraft(
            req: req,
            courseID: courseID,
            draftID: payload.draftIDRaw,
            sectionIDRaw: payload.sectionIDRaw
        )
        guard let setupID = setup.id else {
            throw WebAssignmentError.internalFailure(reason: "Draft test setup persisted without an id")
        }

        var formState = loadDraftFormState(req: req, draftID: setupID)
        formState.assignmentName = payload.assignmentName
        formState.dueAt = payload.dueAt
        formState.sectionID = payload.sectionIDRaw
        formState.requiredPlatform = payload.requiredPlatform
        formState.requiredArchitecture = payload.requiredArchitecture
        formState.requiredLanguagesCSV = payload.requiredLanguagesCSV
        formState.requiredCapabilitiesCSV = payload.requiredCapabilitiesCSV

        var service = NewAssignmentDraftService(
            req: req,
            setup: setup,
            setupID: setupID,
            userID: userID,
            courseID: courseID,
            formState: formState,
            payload: payload
        )
        let outcome = try await service.perform()

        saveDraftFormState(req: req, draftID: setupID, state: service.formState)

        let errorMessage: String? = {
            if case .validationFailed(let msg) = outcome { return msg }
            return nil
        }()
        return redirectToNewAssignmentDraft(
            req: req,
            draftID: setupID,
            assignmentName: payload.assignmentName,
            dueAt: payload.dueAt,
            sectionID: payload.sectionIDRaw,
            notice: nil,
            error: errorMessage
        )
    }

    // MARK: - updateNewAssignmentDraft helpers

    fileprivate func parseNewAssignmentDraftPayload(req: Request) throws -> NewAssignmentDraftPayload {
        let bodyMany = try? req.content.decode(DraftBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(DraftBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Invalid assignment draft payload")
        }

        let assignmentName =
            try multipartTextField(named: ["assignmentName"], from: req)
            ?? bodyMany?.assignmentName
            ?? bodySingle?.assignmentName
            ?? ""
        let dueAt =
            try multipartTextField(named: ["dueAt"], from: req)
            ?? bodyMany?.dueAt
            ?? bodySingle?.dueAt
            ?? ""
        let sectionIDRaw =
            try multipartTextField(named: ["sectionID"], from: req)
            ?? bodyMany?.sectionID
            ?? bodySingle?.sectionID
            ?? ""
        let draftIDRaw =
            try multipartTextField(named: ["draftID"], from: req)
            ?? bodyMany?.draftID
            ?? bodySingle?.draftID
        let action =
            (try multipartTextField(named: ["draftAction"], from: req)
            ?? bodyMany?.draftAction
            ?? bodySingle?.draftAction
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFiles =
            (try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? bodyMany?.suiteFiles
            ?? (bodySingle?.suiteFiles.map { [$0] } ?? []))
            .filter { $0.data.readableBytes > 0 }
        let suiteConfigRaw =
            try multipartTextField(named: ["suiteConfig"], from: req)
            ?? bodyMany?.suiteConfig
            ?? bodySingle?.suiteConfig
        let requiredPlatform =
            try multipartTextField(named: ["requiredPlatform"], from: req)
            ?? bodyMany?.requiredPlatform
            ?? bodySingle?.requiredPlatform
            ?? ""
        let requiredArchitecture =
            try multipartTextField(named: ["requiredArchitecture"], from: req)
            ?? bodyMany?.requiredArchitecture
            ?? bodySingle?.requiredArchitecture
            ?? ""
        let requiredLanguagesCSV =
            try multipartTextField(named: ["requiredLanguagesCSV"], from: req)
            ?? bodyMany?.requiredLanguagesCSV
            ?? bodySingle?.requiredLanguagesCSV
            ?? ""
        let requiredCapabilitiesCSV =
            try multipartTextField(named: ["requiredCapabilitiesCSV"], from: req)
            ?? bodyMany?.requiredCapabilitiesCSV
            ?? bodySingle?.requiredCapabilitiesCSV
            ?? ""

        return NewAssignmentDraftPayload(
            assignmentName: assignmentName,
            dueAt: dueAt,
            sectionIDRaw: sectionIDRaw,
            draftIDRaw: draftIDRaw,
            action: action,
            assignmentNotebookFile: assignmentNotebookFile,
            solutionNotebookFile: solutionNotebookFile,
            suiteFiles: suiteFiles,
            suiteConfigRaw: suiteConfigRaw,
            requiredPlatform: requiredPlatform,
            requiredArchitecture: requiredArchitecture,
            requiredLanguagesCSV: requiredLanguagesCSV,
            requiredCapabilitiesCSV: requiredCapabilitiesCSV
        )
    }

    // MARK: - POST /instructor/new/save

    @Sendable
    func saveNewAssignment(req: Request) async throws -> Response {
        let saveUser = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: saveUser)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "creating an assignment")
        }

        let form = try parseSaveNewAssignmentForm(req: req)
        let validation = try await validateSaveNewAssignment(
            req: req,
            saveUserID: saveUser.id,
            form: form
        )
        let validated: ValidatedSaveNewAssignment
        switch validation {
        case .valid(let v): validated = v
        case .redirect(toURL: let url): return req.redirect(to: url)
        }

        let paths = try writeNewAssignmentNotebookAndPlanPaths(req: req, validated: validated)

        let setupPackage = try rebuildNewAssignmentSuiteZip(
            validated: validated,
            zipPath: paths.zipPath
        )

        let resolvedSectionID: UUID? = try await resolveSectionID(
            validated.sectionIDRaw, courseID: courseID, db: req.db)
        let sectionGradingMode = try await newAssignmentResolvedGradingMode(
            req: req, sectionID: resolvedSectionID)

        // Preserve the draft's pattern families, sections, and notebook
        // checks across the manifest rebuild.
        let preserved = preservedDraftDescriptors(draftSetup: validated.draftSetup)

        let manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile,
            gradingMode: sectionGradingMode,
            patternFamilies: preserved.families,
            notebookChecks: preserved.checks,
            sections: preserved.sections
        )
        let setup = try await persistNewAssignmentSetup(
            req: req,
            draftSetup: validated.draftSetup,
            setupID: paths.setupID,
            manifest: manifest,
            zipPath: paths.zipPath,
            notebookPath: paths.notebookPath,
            courseID: courseID
        )

        try await reapplyDraftMetadataIfNeeded(
            req: req,
            setup: setup,
            preserved: preserved,
            setupPackage: setupPackage
        )
        extractSupportFilesToSharedDirectory(
            zipPath: paths.zipPath,
            setupID: paths.setupID,
            testSuiteScripts: Set(setupPackage.testSuites.map { $0.script }),
            testSetupsDirectory: req.application.testSetupsDirectory
        )

        let shouldQueueValidation = !setupPackage.testSuites.isEmpty
        if shouldQueueValidation {
            let hasEligibleRunner = try await ensureCompatibleValidationRunnerAvailability(
                req: req,
                requirements: validated.requirementSpec
            )
            guard hasEligibleRunner else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: validated.draftID,
                    assignmentName: validated.title,
                    dueAt: validated.dueAtRaw,
                    sectionID: validated.sectionIDRaw,
                    notice: nil,
                    error: "No compatible active runner is available to validate this assignment."
                )
            }
        }

        let assignment = try await createNewAssignmentRow(
            req: req,
            validated: validated,
            courseID: courseID,
            sectionID: resolvedSectionID,
            setupID: paths.setupID,
            shouldQueueValidation: shouldQueueValidation
        )

        if shouldQueueValidation {
            try await enqueueNewAssignmentValidationSubmission(
                req: req,
                assignment: assignment,
                validated: validated,
                setupID: paths.setupID
            )
        }
        if !validated.draftID.isEmpty {
            clearDraftFormState(req: req, draftID: validated.draftID)
        }
        return req.redirect(to: "/instructor")
    }

    fileprivate struct DraftBodyMany: Content {
        var assignmentName: String?
        var dueAt: String?
        var sectionID: String?
        var draftID: String?
        var draftAction: String?
        var assignmentNotebookFile: File?
        var solutionNotebookFile: File?
        var suiteFiles: [File]?
        var suiteConfig: String?
        var requiredPlatform: String?
        var requiredArchitecture: String?
        var requiredLanguagesCSV: String?
        var requiredCapabilitiesCSV: String?
    }

    fileprivate struct DraftBodySingle: Content {
        var assignmentName: String?
        var dueAt: String?
        var sectionID: String?
        var draftID: String?
        var draftAction: String?
        var assignmentNotebookFile: File?
        var solutionNotebookFile: File?
        var suiteFiles: File?
        var suiteConfig: String?
        var requiredPlatform: String?
        var requiredArchitecture: String?
        var requiredLanguagesCSV: String?
        var requiredCapabilitiesCSV: String?
    }

    // MARK: - saveNewAssignment helpers

    fileprivate struct NewAssignmentPaths {
        let setupID: String
        let notebookPath: String
        let zipPath: String
    }

    fileprivate struct PreservedDraftDescriptors {
        let props: TestProperties?
        let families: [PatternFamily]
        let checks: [NotebookCheck]
        let sections: [TestSuiteSection]

        var needsApply: Bool {
            !families.isEmpty || !checks.isEmpty || !sections.isEmpty
        }
    }

    /// Writes the assignment notebook to disk and returns the planned
    /// setup ID, notebook path, and zip path.
    fileprivate func writeNewAssignmentNotebookAndPlanPaths(
        req: Request,
        validated: ValidatedSaveNewAssignment
    ) throws -> NewAssignmentPaths {
        let assignmentNotebook = normalizeNotebookForJupyterLite(validated.assignmentNotebookRaw)
        let setupID = validated.draftSetup?.id ?? "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookFilename = notebookFilenameForStorage(
            uploadedName: validated.uploadedAssignmentNotebookFilename ?? validated.draftState.assignmentNotebookName,
            fallback: validated.draftSetup?.notebookPath
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "assignment.ipynb"
        )
        let notebookDir = setupsDir + "notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let notebookPath = notebookDir + notebookFilename
        let zipPath = validated.draftSetup?.zipPath ?? (setupsDir + "\(setupID).zip")
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        return NewAssignmentPaths(setupID: setupID, notebookPath: notebookPath, zipPath: zipPath)
    }

    /// Resolves the suite files + suite config (preferring uploaded over
    /// draft-derived) and runs the zip rebuild.
    fileprivate func rebuildNewAssignmentSuiteZip(
        validated: ValidatedSaveNewAssignment,
        zipPath: String
    ) throws -> RunnerSetupPackage {
        let resolvedSuiteFiles: [File] = {
            if !validated.suiteFiles.isEmpty { return validated.suiteFiles }
            guard let draftSetup = validated.draftSetup else { return [] }
            return editableSuiteRowsForSetup(draftSetup).compactMap { row in
                guard let data = extractZipEntry(zipPath: draftSetup.zipPath, entryName: row.name) else { return nil }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return File(data: buffer, filename: row.name)
            }
        }()
        let resolvedSuiteConfigJSON: String? = {
            if let suiteConfigRaw = validated.suiteConfigRaw,
                !suiteConfigRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return suiteConfigRaw
            }
            return validated.draftSetup?.manifest.data(using: .utf8).flatMap { data in
                guard let props = decodeManifest(from: data) else { return nil }
                let rows = props.testSuites.enumerated().map { index, entry in
                    ReindexedSuiteConfigRow(
                        index: index,
                        isTest: entry.tier.rawValue != "support",
                        tier: entry.tier.rawValue,
                        order: index + 1,
                        dependsOn: entry.dependsOn,
                        points: entry.points,
                        displayName: entry.name
                    )
                }
                guard let encoded = try? JSONEncoder().encode(rows) else { return nil }
                return String(data: encoded, encoding: .utf8)
            }
        }()
        // Merge 'existing' (name-based) config rows with files from the draft ZIP so
        // buildSuiteEntries can decode every row using its required `index` field.
        let (mergedSuiteFiles, mergedConfigJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: resolvedSuiteFiles,
            suiteConfigJSON: resolvedSuiteConfigJSON,
            draftZipPath: validated.draftSetup?.zipPath
        )
        return try createRunnerSetupZip(
            suiteFiles: mergedSuiteFiles,
            suiteConfigJSON: mergedConfigJSON,
            zipPath: zipPath
        )
    }

    fileprivate func newAssignmentResolvedGradingMode(
        req: Request,
        sectionID: UUID?
    ) async throws -> String {
        if let sid = sectionID,
            let sec = try await APICourseSection.find(sid, on: req.db)
        {
            return sec.defaultGradingMode  // "browser" | "worker"
        }
        return "worker"
    }

    /// Each was added on a different version (v0.4.77 for families,
    /// v0.4.96 for sections, v0.4.113 for checks); without forwarding all
    /// three, `makeWorkerManifestJSON` emits empty fields and any
    /// sections/checks/families authored on the create page get dropped
    /// on publish.  Regression guard:
    /// `testCreatePublishPreservesSectionsAndChecks`.
    fileprivate func preservedDraftDescriptors(draftSetup: APITestSetup?) -> PreservedDraftDescriptors {
        let draftProps: TestProperties? = {
            guard let existingManifest = draftSetup?.manifest,
                let data = existingManifest.data(using: .utf8)
            else { return nil }
            return decodeManifest(from: data)
        }()
        return PreservedDraftDescriptors(
            props: draftProps,
            families: draftProps?.patternFamilies ?? [],
            checks: draftProps?.notebookChecks ?? [],
            sections: draftProps?.sections ?? []
        )
    }

    // The parameter list here mirrors the call site exactly; bundling
    // them into a struct would push the same names one layer down.
    // swiftlint:disable:next function_parameter_count
    fileprivate func persistNewAssignmentSetup(
        req: Request,
        draftSetup: APITestSetup?,
        setupID: String,
        manifest: String,
        zipPath: String,
        notebookPath: String,
        courseID: UUID
    ) async throws -> APITestSetup {
        let setup =
            draftSetup
            ?? APITestSetup(
                id: setupID,
                manifest: manifest,
                zipPath: zipPath,
                notebookPath: notebookPath,
                courseID: courseID
            )
        setup.manifest = manifest
        setup.zipPath = zipPath
        setup.notebookPath = notebookPath
        setup.courseID = courseID
        try await setup.save(on: req.db)
        return setup
    }

    /// Re-runs applyPatternFamilies so generated scripts survive the zip
    /// rebuild AND so each entry's `sectionID` is restored —
    /// `setupPackage.testSuites` loses sectionID through the
    /// ReindexedSuiteConfigRow JSON round-trip, and the `authoredItems`
    /// path is the only one that re-stamps it from the draft manifest.
    /// Run unconditionally when ANY of families/checks/sections exist;
    /// the previous gate (families-only) silently dropped sections +
    /// checks on publish.
    fileprivate func reapplyDraftMetadataIfNeeded(
        req: Request,
        setup: APITestSetup,
        preserved: PreservedDraftDescriptors,
        setupPackage: RunnerSetupPackage
    ) async throws {
        guard preserved.needsApply else { return }
        let authoredItems = authoredSuiteItemsFromDraftManifest(
            draftProps: preserved.props,
            newRawEntries: setupPackage.testSuites
        )
        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: preserved.families,
            nextChecks: preserved.checks.isEmpty ? nil : preserved.checks,
            authoredItems: authoredItems,
            sections: preserved.sections.isEmpty ? nil : preserved.sections,
            on: req.db
        )
    }

    fileprivate func createNewAssignmentRow(
        req: Request,
        validated: ValidatedSaveNewAssignment,
        courseID: UUID,
        sectionID: UUID?,
        setupID: String,
        shouldQueueValidation: Bool
    ) async throws -> APIAssignment {
        let assignment = try await createAssignmentWithUniquePublicID(
            req: req,
            testSetupID: setupID,
            title: validated.title,
            dueAt: validated.dueAt,
            isOpen: false,
            sortOrder: try await nextAssignmentSortOrder(req: req),
            validationStatus: shouldQueueValidation ? "pending" : nil,
            validationSubmissionID: nil,
            sectionID: sectionID,
            courseID: courseID
        )
        if let requirements = validated.requirementSpec {
            let requirement = AssignmentRequirement(
                assignmentID: try assignment.requireID(),
                specification: requirements
            )
            try await requirement.save(on: req.db)
        }
        return assignment
    }

    fileprivate func enqueueNewAssignmentValidationSubmission(
        req: Request,
        assignment: APIAssignment,
        validated: ValidatedSaveNewAssignment,
        setupID: String
    ) async throws {
        let validationSubmissionID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: setupID,
            solutionNotebookData: normalizeNotebookForJupyterLite(validated.solutionNotebookRaw),
            filename: validated.uploadedSolutionNotebookFilename
                ?? validated.draftState.solutionNotebookName
                ?? "solution.ipynb"
        )
        assignment.validationSubmissionID = validationSubmissionID
        try await assignment.save(on: req.db)
        await ensureValidationRunnerAvailability(req: req)
    }

    // MARK: - POST /instructor
    // Creates a draft (isOpen: false) assignment and redirects to the validate page.

    // The argument list mirrors the URL query string the redirect builds —
    // each parameter is an independent named field on the new-assignment
    // form, so bundling them into a struct would only push the same names
    // one layer down without removing any.
    // swiftlint:disable:next function_parameter_count
    private func redirectToNewAssignmentDraft(
        req: Request,
        draftID: String,
        assignmentName: String,
        dueAt: String,
        sectionID: String,
        notice: String?,
        error: String?
    ) -> Response {
        var parts: [String] = [
            "draftID=\(urlEncode(draftID))",
            "assignmentName=\(urlEncode(assignmentName))",
            "dueAt=\(urlEncode(dueAt))",
            "sectionID=\(urlEncode(sectionID))",
        ]
        if let notice, !notice.isEmpty {
            parts.append("notice=\(urlEncode(notice))")
        }
        if let error, !error.isEmpty {
            parts.append("error=\(urlEncode(error))")
        }
        return req.redirect(to: "/instructor/new?\(parts.joined(separator: "&"))")
    }

    private func resolveOrCreateNewAssignmentDraft(
        req: Request,
        courseID: UUID,
        draftID: String?,
        sectionIDRaw: String
    ) async throws -> APITestSetup {
        if let draftID,
            !draftID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let existing = try await APITestSetup.find(draftID, on: req.db)
        {
            return existing
        }

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = req.application.testSetupsDirectory + "\(setupID).zip"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let gradingMode = try await newAssignmentSectionGradingMode(
            req: req,
            courseID: courseID,
            sectionIDRaw: sectionIDRaw
        )
        let manifest = try makeWorkerManifestJSON(
            testSuites: [],
            includeMakefile: false,
            gradingMode: gradingMode,
            starterNotebook: "assignment.ipynb"
        )
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: nil,
            courseID: courseID
        )
        try await setup.save(on: req.db)
        return setup
    }

    // newAssignmentSectionGradingMode moved to file scope (below the
    // extension) so `NewAssignmentDraftService` can call it without
    // needing visibility into the extension's privates.

    @Sendable
    func publish(req: Request) async throws -> Response {
        struct PublishBody: Content {
            var testSetupID: String
            var title: String
            var dueAt: String?  // ISO8601 string from datetime-local input, or empty
        }

        let publishUser = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: publishUser)
        let body = try req.content.decode(PublishBody.self)

        guard try await APITestSetup.find(body.testSetupID, on: req.db) != nil else {
            throw WebAssignmentError.invalidParameter(
                name: "testSetupID",
                reason: "unknown test setup '\(body.testSetupID)'"
            )
        }

        // Reject if a draft/open assignment already exists for this setup.
        let existing = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == body.testSetupID)
            .count()
        if existing > 0 {
            // Already published — redirect back.
            return req.redirect(to: "/instructor")
        }

        let due: Date?
        if let raw = body.dueAt, !raw.isEmpty {
            // datetime-local sends "2026-04-01T14:00" — try ISO8601 with and without seconds.
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: raw) {
                due = d
            } else {
                // Try without timezone (datetime-local format)
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
                due = fmt.date(from: raw)
            }
        } else {
            due = nil
        }

        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "publishing an assignment")
        }

        let assignment = try await createAssignmentWithUniquePublicID(
            req: req,
            testSetupID: body.testSetupID,
            title: body.title.isEmpty ? body.testSetupID : body.title,
            dueAt: due,
            isOpen: false,  // stays closed until instructor validates + opens
            sortOrder: try await nextAssignmentSortOrder(req: req),
            courseID: courseID
        )
        return req.redirect(to: "/instructor/\(assignment.publicID)/validate")
    }

}

// MARK: - File-scope helpers

/// Resolves the default grading mode for the section identified by
/// `sectionIDRaw` within `courseID`.  Falls back to `"worker"` when
/// the section can't be resolved (e.g., the form's "Ungrouped"
/// pseudo-section, or a missing section row).
///
/// File-scope so `NewAssignmentDraftService` (in `Services/`) can
/// call it without needing to access the route extension's privates.
func newAssignmentSectionGradingMode(
    req: Request,
    courseID: UUID,
    sectionIDRaw: String
) async throws -> String {
    guard let sid = try await resolveSectionID(sectionIDRaw, courseID: courseID, db: req.db),
        let sec = try await APICourseSection.find(sid, on: req.db)
    else {
        return "worker"
    }
    return sec.defaultGradingMode
}

// APIServer/Services/NotebookWorkingCopyStore.swift
//
// Filesystem service for per-user JupyterLite notebook working copies.
// Owns path planning, the closed-assignment participation gate, working-copy
// seeding + personalization substitution, submission-history selection, the
// latest-submission fallback, support-file symlinks, and the one-time boot
// cleanup of pre-v0.4 legacy notebook copies.
//
// Extracted from WebRoutes+Notebook.swift (which keeps only the route
// handlers) — no behaviour changes, except that the legacy-copy sweep now
// runs once at boot instead of on every notebook page view.

import Core
import Fluent
import Foundation
import Vapor

func userNotebookWorkingCopyRelativePath(setupID: String, userID: UUID) -> String {
    userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: .assignment)
}

func notebookFileKind(from rawValue: String?) -> NotebookFileKind {
    NotebookFileKind(rawValue: (rawValue ?? "").lowercased()) ?? .assignment
}

private func userNotebookFilename(fileKind: NotebookFileKind) -> String {
    switch fileKind {
    case .assignment: return "assignment.ipynb"
    case .solution: return "solution.ipynb"
    }
}

func userNotebookWorkingCopyRelativePath(
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind
) -> String {
    "users/\(userID.uuidString.lowercased())/\(setupID)/\(userNotebookFilename(fileKind: fileKind))"
}

/// Whether `userID` has previously engaged with `assignment`: a durable
/// participation row exists (written the first time they were given the
/// assignment's materials) or they have at least one student submission.
/// Drives the closed-assignment access gate so a student can return to a
/// closed assignment to review past work, while a not-yet-opened lab they
/// have never touched stays out of reach.
///
/// The submission check is a permanent safety net that also bridges
/// students who submitted before the participation table existed; a closed
/// assignment they review then lazily backfills its own participation row.
func studentHasOpenedAssignment(
    assignment: APIAssignment,
    userID: UUID,
    on db: Database
) async throws -> Bool {
    if let assignmentID = assignment.id,
        try await AssignmentParticipationStore.hasParticipation(
            userID: userID, assignmentID: assignmentID, on: db)
    {
        return true
    }
    return try await APISubmission.query(on: db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$userID == userID)
        .filter(\.$kind == APISubmission.Kind.student)
        .count() > 0
}

/// Closed-assignment access gate for the student-facing notebook page and
/// upload form.  Returns a redirect `Response` to the dashboard when a student
/// must be bounced from a closed assignment they have never engaged with;
/// otherwise records their first access durably and returns nil.  Instructors
/// and admins always pass through (no redirect, no record).
func closedAssignmentGate(
    req: Request,
    user: APIUser,
    userID: UUID,
    assignment: APIAssignment?,
    isClosed: Bool
) async throws -> Response? {
    // Course staff (TA+ or admin) bypass the closed-assignment gate for their
    // own course (#417 Slice G — was the global `user.isInstructor`).
    if let assignmentCourseID = assignment?.courseID,
        try await isCourseStaff(user, inCourse: assignmentCourseID, db: req.db)
    {
        return nil
    }
    if isClosed, let assignment {
        // A published-then-closed assignment is openable read-only — a student
        // may return to a recently-closed lab to review it. Only bounce a
        // student from a closed assignment that isn't student-visible by state
        // (a preview, a not-yet-opened scheduled assignment, or an unpublished
        // draft) and that they have never engaged with. Submission stays gated
        // separately by requireOpenStudentAssignment, so this view is read-only.
        var mayView = assignmentVisibleToStudentByState(assignment)
        if !mayView {
            mayView = try await studentHasOpenedAssignment(
                assignment: assignment, userID: userID, on: req.db)
        }
        if !mayView {
            return req.redirect(to: "/")
        }
    }
    if let assignmentID = assignment?.id {
        try await AssignmentParticipationStore.recordFirstAccess(
            userID: userID, assignmentID: assignmentID, on: req.db)
    }
    return nil
}

/// Reads the mtime (Unix epoch seconds) of the working-copy notebook
/// file at `absolutePath`.  Returns 0 if the file is missing or its
/// attributes can't be read.  Used by the notebook page to surface
/// `data-working-copy-mtime` to the client so the in-browser
/// IndexedDB sync can detect server-side overwrites (e.g. instructor
/// reset) and force-reseed.
func workingCopyMtimeEpoch(absolutePath: String) -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: absolutePath),
        let mtime = attrs[.modificationDate] as? Date
    else {
        return 0
    }
    return Int(mtime.timeIntervalSince1970)
}

func ensureUserNotebookWorkingCopy(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup,
    relativePath: String? = nil,
    defaultData: Data? = nil,
    overwriteWith: Data? = nil
) async throws -> Data {
    let fileManager = FileManager.default
    let resolvedRelativePath = relativePath ?? userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
    let workingCopyPath =
        req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + resolvedRelativePath
    let workingCopyDir = (workingCopyPath as NSString).deletingLastPathComponent

    // All synchronous filesystem work below runs on the thread pool (#1156):
    // this function executes on every notebook page/source request, and a
    // burst of them (a lab section opening an assignment) previously parked
    // cooperative-pool threads on disk reads/writes.
    if let overwriteWith {
        try await runBlocking(on: req) {
            try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
            try overwriteWith.write(to: URL(fileURLWithPath: workingCopyPath))
        }
        await createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)
        await writeDatasetFiles(req: req, setup: fallbackSetup, userID: userID, studentDir: workingCopyDir)
        return overwriteWith
    }

    let existingWorkingCopy: Data? = try await runBlocking(on: req) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: workingCopyPath)),
            !data.isEmpty,
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return data
    }
    if let existingData = existingWorkingCopy {
        // Symlinks are idempotent — run on every visit so existing working copies
        // also pick up support files when the feature is first deployed.
        await createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)
        await writeDatasetFiles(req: req, setup: fallbackSetup, userID: userID, studentDir: workingCopyDir)
        return existingData
    }

    let seedData =
        if let defaultData {
            defaultData
        } else {
            try await latestNotebookSubmissionData(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: fallbackSetup
            ).data
        }

    // Slice 1 + Slice 2 + Slice 4: substitute `{{name}}` placeholders in
    // the starter notebook.  Slice 5: the evaluator can now import
    // instructor-uploaded `.py` support files (and the auto-extracted
    // `solution.py` from solution.ipynb).  Failures fall back to
    // un-substituted seedData; the editor's save-time check is the
    // primary gate.
    let processedData = await applyNotebookSubstitutionsIfNeeded(
        seedData: seedData,
        setup: fallbackSetup,
        userID: userID,
        db: req.db,
        supportFilesDirectory: req.application.testSetupsDirectory + "shared/\(setupID)/",
        logger: req.logger
    )

    try await runBlocking(on: req) {
        try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
        try processedData.write(to: URL(fileURLWithPath: workingCopyPath))
    }
    await createSupportFileSymlinks(req: req, setup: fallbackSetup, studentDir: workingCopyDir)
    await writeDatasetFiles(req: req, setup: fallbackSetup, userID: userID, studentDir: workingCopyDir)

    return processedData
}

/// Overwrites `userID`'s working copy with `starter` after applying the same
/// per-student `{{name}}` personalization the first-open seeding path
/// performs.  All three reset-notebook actions (student self-service and both
/// instructor-driven ones) funnel through here: resetting a personalized
/// assignment must land the student on their substituted starter, never the
/// raw template (which would leave `name = {{name}}` cells that fail with
/// NameError).  Substitution failures soft-fail to the raw starter, matching
/// the seeding path.
func overwriteUserNotebookWithPersonalizedStarter(
    req: Request,
    setup: APITestSetup,
    setupID: String,
    userID: UUID,
    starter: Data
) async throws -> Data {
    let personalized = await applyNotebookSubstitutionsIfNeeded(
        seedData: starter,
        setup: setup,
        userID: userID,
        db: req.db,
        supportFilesDirectory: req.application.testSetupsDirectory + "shared/\(setupID)/",
        logger: req.logger
    )
    return try await ensureUserNotebookWorkingCopy(
        req: req,
        setupID: setupID,
        userID: userID,
        fallbackSetup: setup,
        overwriteWith: personalized
    )
}

/// Slice 1 + Slice 2: applies `{{name}}` substitutions to a notebook.
/// Sources:
///   - `globalVariables` (Slice 1, literals)
///   - section `variables` (Slice 1, literals)
///   - `globalExpressions` (Slice 2, evaluated per-student against the
///     `(userID, assignment)` seed via PersonalizationEvaluator)
///
/// Returns the original data unchanged when:
/// - the manifest can't be decoded;
/// - the manifest has no variables AND no expressions;
/// - the notebook JSON is malformed (logged, never crashes);
/// - the per-student eval fails (logged, falls back to literals only).
private func applyNotebookSubstitutionsIfNeeded(
    seedData: Data,
    setup: APITestSetup,
    userID: UUID,
    db: Database,
    supportFilesDirectory: String? = nil,
    logger: Logger
) async -> Data {
    guard let manifestData = setup.manifest.data(using: .utf8),
        let manifest = try? ManifestCodec.decoder.decode(
            TestProperties.self,
            from: manifestData)
    else {
        return seedData
    }

    // A seed is only needed to evaluate per-student expressions; literal-only
    // assignments substitute without one (and without an assignment lookup).
    var seedHex: String?
    if manifest.hasExpressions, let setupID = setup.id {
        if let assignment = try? await APIAssignment.query(on: db)
            .filter(\.$testSetupID == setupID)
            .first(),
            let assignmentID = assignment.id
        {
            seedHex = try? await AssignmentSeedStore.ensureSeed(
                userID: userID, assignmentID: assignmentID, on: db)
        }
        if seedHex == nil {
            logger.warning(
                "Could not resolve a seed for setup \(setupID); substituting literal values only.")
        }
    }

    let resolution = await PersonalizationSubstitution.resolve(
        manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportFilesDirectory,
        language: AssignmentLanguage.resolve(for: setup, manifest: manifest))
    if let evalError = resolution.evaluationError {
        logger.warning(
            Logger.Message(
                stringLiteral:
                    "Personalization evaluator failed for setup \(setup.id ?? "<nil>"): \(evalError). "
                    + "Notebook will be substituted with literal values only."))
    }

    guard !resolution.substitutions.isEmpty else { return seedData }
    return
        (try? applySubstitutions(
            seedData, substitutions: resolution.substitutions,
            setup: setup, logger: logger)) ?? seedData
}

private func applySubstitutions(
    _ seedData: Data,
    substitutions: [String: String],
    setup: APITestSetup,
    logger: Logger
) throws -> Data {
    do {
        return try NotebookSubstitution.apply(
            notebookData: seedData,
            substitutions: substitutions,
            strict: false  // editor save-time scan is authoritative; soft-fail at runtime
        )
    } catch {
        logger.warning("Notebook substitution failed for setup \(setup.id ?? "<nil>"): \(error)")
        return seedData
    }
}

func solutionNotebookData(
    for assignment: APIAssignment?,
    setup: APITestSetup,
    db: Database
) async throws -> Data {
    if let entryName = listZipEntries(zipPath: setup.zipPath).first(where: { $0.hasPrefix("solution.") }),
        let data = extractZipEntry(zipPath: setup.zipPath, entryName: entryName),
        !data.isEmpty
    {
        return normalizeNotebookForJupyterLite(data)
    }

    if let validationID = assignment?.validationSubmissionID,
        let validationSubmission = try await APISubmission.find(validationID, on: db),
        let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
        !data.isEmpty
    {
        return normalizeNotebookForJupyterLite(data)
    }

    if let setupID = assignment?.testSetupID,
        let fallbackSubmission = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first(),
        let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
        !data.isEmpty
    {
        return normalizeNotebookForJupyterLite(data)
    }

    throw AppError.notFound(resource: "Solution notebook (not yet available for this assignment)")
}

func notebookDataForHistorySelection(
    req: Request,
    caller: APIUser,
    submissionID: String,
    setupID: String,
    userID: UUID
) async throws -> Data {
    guard let submission = try await APISubmission.find(submissionID, on: req.db) else {
        throw AppError.notFound(resource: "Submission")
    }
    guard submission.kind == APISubmission.Kind.student else {
        throw Abort(.forbidden)
    }
    let isStaff = try await isSubmissionStaff(caller, submission: submission, on: req.db)
    if !isStaff && submission.userID != userID {
        throw Abort(.forbidden)
    }
    guard submission.testSetupID == setupID else {
        throw AppError.badRequest(reason: "Submission does not belong to this assignment")
    }

    let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
    let nameExt = (submission.filename ?? "").lowercased()
    guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
        throw AppError.badRequest(reason: "Only notebook submissions can be opened in notebook view")
    }

    let dataURL = URL(fileURLWithPath: submission.zipPath)
    guard let data = try? Data(contentsOf: dataURL),
        (try? JSONSerialization.jsonObject(with: data)) != nil
    else {
        throw AppError.notFound(resource: "Notebook artifact for this submission")
    }
    return normalizeNotebookForJupyterLite(data)
}

func latestNotebookSubmissionData(
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
        let zipPath = submission.zipPath
        let candidate: Data? = try await runBlocking(on: req) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: zipPath)),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            else { return nil }
            return data
        }
        guard let data = candidate else { continue }
        return (data, submission.filename)
    }

    let fallbackFilename: String? = {
        guard let path = fallbackSetup.notebookPath, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()
    // The fallback reads the setup's canonical notebook — cached and
    // resolved on the thread pool (#1156/#1171).
    let fallbackData = try await req.application.notebookBytesCache.notebookData(
        for: NotebookSourceRef(fallbackSetup))
    return (fallbackData, fallbackFilename)
}

/// Creates read-only symlinks for support files (zip entries that are not test suite
/// scripts or canonical notebooks) inside the student's JupyterLite working directory.
///
/// Symlinks point to the shared extraction in `{testSetupsDir}/shared/{setupID}/`
/// that is populated by `extractSupportFilesToSharedDirectory` when the test setup
/// is created or edited. Only files that exist in the shared directory are linked;
/// missing files are silently skipped so a missing shared dir never breaks notebook access.
func createSupportFileSymlinks(req: Request, setup: APITestSetup, studentDir: String) async {
    guard let setupID = setup.id else { return }

    // Derive the list of support files: everything in the zip except test suite scripts
    // and the canonical notebooks.
    guard let manifestData = setup.manifest.data(using: .utf8),
        let props = decodeManifest(from: manifestData)
    else { return }

    let testScriptNames = Set(props.testSuites.map { $0.script })
    let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]
    // Grader-only support files (e.g. an answer-key helper or a reserved
    // holdout) reach the worker via the zip but are withheld from every
    // student-facing path — here, the editor must not symlink them into the
    // student's working copy. See docs/datasets.md (option B).
    let graderOnly = props.graderOnlyFileSet
    // Dataset files are written as real per-student files by writeDatasetFiles;
    // skip symlinking them here so the symlink doesn't shadow the real file.
    let datasetFilenames = Set(props.datasets.map { $0.file })
    // Cached: this pass runs on every notebook visit (the symlinks are
    // idempotent), so listing the zip fresh each time would spawn a serialized
    // `unzip` subprocess per load. The cache busts when the zip's mtime/size
    // changes — i.e. whenever the instructor edits support files.
    let allEntries = await req.application.zipEntryListCache.entries(zipPath: setup.zipPath)
    let supportNames = allEntries.filter {
        !testScriptNames.contains($0) && !reservedNames.contains($0)
            && !graderOnly.contains($0) && !datasetFilenames.contains($0)
    }
    guard !supportNames.isEmpty else { return }

    let sharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"

    // The exists/exists/symlink triple per support file is synchronous
    // filesystem work on every notebook visit — run the whole pass on the
    // thread pool (#1156).
    try? await runBlocking(on: req) {
        let fm = FileManager.default
        for name in supportNames {
            let src = sharedDir + name
            let dest = studentDir + "/" + name
            guard !fm.fileExists(atPath: dest) else { continue }  // idempotent
            guard fm.fileExists(atPath: src) else { continue }  // skip if not yet extracted
            try? fm.createSymbolicLink(atPath: dest, withDestinationPath: src)
        }
    }
}

/// Materializes per-student dataset slices into the student's JupyterLite working
/// directory. Dataset files are written as real files (not symlinks) so each student
/// sees only their own rows. Idempotent — safe to call on every visit; always
/// overwrites with the current slice so a spec change is picked up automatically.
/// A strict no-op when the assignment declares no datasets.
func writeDatasetFiles(
    req: Request,
    setup: APITestSetup,
    userID: UUID,
    studentDir: String
) async {
    guard let manifestData = setup.manifest.data(using: .utf8),
        let props = decodeManifest(from: manifestData),
        !props.datasets.isEmpty,
        let setupID = setup.id
    else { return }

    guard
        let assignment = try? await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first(),
        let assignmentID = assignment.id
    else { return }

    guard
        let seedHex = try? await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: req.db)
    else { return }

    let sharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"

    // Dataset resolution reads the source CSV and materializes a per-student
    // slice, then writes one file per dataset — synchronous I/O + CPU on
    // every visit to a dataset-carrying assignment. Thread pool (#1156).
    try? await runBlocking(on: req) {
        guard
            let files = DatasetResolver.resolve(
                manifest: props, seedHex: seedHex, sourceDirectory: sharedDir)
        else { return }

        for (filename, content) in files {
            // Defense-in-depth (#1104): resolver keys are validated bare
            // filenames, but never join an unvetted name onto the student dir.
            guard FilenameSafety.bareFilename(filename) != nil else { continue }
            let dest = studentDir + "/" + filename
            try? content.write(toFile: dest, atomically: true, encoding: .utf8)
        }
    }
}

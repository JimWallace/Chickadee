// APIServer/Services/NewAssignmentDraftService.swift
//
// Per-action dispatch for the new-assignment "Save draft" partial-form
// endpoint (`POST /instructor/new/draft`).  Each action verb the form
// can send — create / upload / clear assignment & solution notebooks,
// replace / clear suite files — has a dedicated method here, mutating
// the service's instance state (setup, formState).
//
// Pre-this-PR the same logic lived as an inline `switch action` inside
// the `updateNewAssignmentDraft` route handler.  The handler had a
// documented preference for keeping it inline because the 9 cases
// shared 5 locals (`setup`, `setupID`, `userID`, `courseID`,
// `formState`) — threading them through per-action free helpers would
// have been a regression.  Pulling those locals onto a service type
// resolves that objection: each method just reads/writes `self`.
//
// Service shape:
//
//   - Plain struct (not actor or class).  A draft update is a single
//     request-scoped object; there is no concurrent access between
//     methods.  Struct + `mutating` keeps Sendable obligations simple
//     and makes unit tests trivial — instantiate, call, assert on
//     `service.setup` / `service.formState`.
//   - `req: Request` is a dependency because the actions touch the
//     filesystem (testSetupsDirectory), the database (setup.save), the
//     logger, and the per-user JupyterLite working copy that lives
//     under `req.application.directory.publicDirectory`.  A future
//     refactor could replace `req` with a smaller interface.
//   - Each method returns a `NewAssignmentDraftActionOutcome` so the
//     handler can distinguish "applied → standard redirect" from
//     "validation failed → redirect with error message in the query."
//     Throwing for true errors (file I/O failure, DB save failure)
//     stays on the throws channel.

import Core
import Fluent
import Foundation
import Vapor

/// Result of dispatching a single draft action.
///
/// The HTTP-shape of the response (303 to which URL, query parameters)
/// is the handler's responsibility — the service only signals what
/// happened.
enum NewAssignmentDraftActionOutcome: Sendable, Equatable {
    /// Action applied successfully.  Handler should redirect to the
    /// standard "draft updated" target with no error in the query.
    case applied

    /// Action validation failed (e.g., upload action with no file).
    /// Handler should redirect to the draft page with this string as
    /// the `error=` query parameter.
    case validationFailed(String)
}

/// Per-request service that owns the state shared across the 9
/// draft-action verbs.  Construct via the handler after parsing the
/// payload + resolving the setup; call `perform()` to apply one
/// action; read back `setup` and `formState` afterwards.
struct NewAssignmentDraftService {
    let req: Request
    let setup: APITestSetup
    let setupID: String
    let userID: UUID
    let courseID: UUID
    var formState: NewAssignmentDraftFormState
    let payload: NewAssignmentDraftPayload

    /// Title used inside generated default notebooks.  Derived from
    /// `payload.assignmentName`; falls back to a generic placeholder
    /// when the instructor hasn't entered one yet.
    var notebookTitle: String {
        let trimmed = payload.assignmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Assignment" : trimmed
    }

    // MARK: - Dispatcher

    /// Dispatches `payload.action` to the matching per-action method.
    /// Unknown actions (including the empty string) are no-ops that
    /// fall through to the standard redirect.
    mutating func perform() async throws -> NewAssignmentDraftActionOutcome {
        switch payload.action {
        case "create-assignment-notebook":
            try await createAssignmentNotebook()
            return .applied
        case "upload-assignment-notebook":
            return try await uploadAssignmentNotebook()
        case "clear-assignment-notebook":
            try await clearAssignmentNotebook()
            return .applied
        case "create-solution-notebook":
            try await createSolutionNotebook()
            return .applied
        case "create-solution-from-assignment":
            try await createSolutionFromAssignment()
            return .applied
        case "upload-solution-notebook":
            return try await uploadSolutionNotebook()
        case "clear-solution-notebook":
            try clearSolutionNotebook()
            return .applied
        case "replace-suite-files":
            try await replaceSuiteFiles()
            return .applied
        case "clear-suite-files":
            try await clearSuiteFiles()
            return .applied
        default:
            return .applied
        }
    }

    // MARK: - Notebook actions

    mutating func createAssignmentNotebook() async throws {
        let data = defaultNotebookData(title: notebookTitle)
        let dir = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        let path = dir + "assignment.ipynb"
        try data.write(to: URL(fileURLWithPath: path))
        setup.notebookPath = path
        try await setup.save(on: req.db)
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            overwriteWith: data
        )
        formState.assignmentNotebookName = "assignment.ipynb"
    }

    mutating func uploadAssignmentNotebook() async throws -> NewAssignmentDraftActionOutcome {
        guard let file = payload.assignmentNotebookFile, file.data.readableBytes > 0 else {
            return .validationFailed("Select an assignment notebook to upload")
        }
        let raw = Data(file.data.readableBytesView)
        guard (try? JSONSerialization.jsonObject(with: raw)) != nil else {
            return .validationFailed("Assignment notebook must be valid JSON (.ipynb)")
        }
        let normalized = normalizeNotebookForJupyterLite(raw)
        let dir = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        let filename = notebookFilenameForStorage(
            uploadedName: file.filename, fallback: "assignment.ipynb")
        let path = dir + filename
        try normalized.write(to: URL(fileURLWithPath: path))
        setup.notebookPath = path
        try await setup.save(on: req.db)
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            overwriteWith: normalized
        )
        formState.assignmentNotebookName = filename
        return .applied
    }

    mutating func clearAssignmentNotebook() async throws {
        removeDraftNotebookFiles(
            req: req,
            setupID: setupID,
            userID: userID,
            fileKind: .assignment,
            persistedPath: setup.notebookPath
        )
        setup.notebookPath = nil
        try await setup.save(on: req.db)
        formState.assignmentNotebookName = nil
    }

    mutating func createSolutionNotebook() async throws {
        let data = defaultNotebookData(title: "\(notebookTitle) Solution")
        let path = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        try data.write(to: URL(fileURLWithPath: path))
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: setupID, userID: userID, fileKind: .solution),
            overwriteWith: data
        )
        formState.solutionNotebookName = "solution.ipynb"
    }

    /// Parity with `createSolutionFromAssignment` (POST /:id/create-solution):
    /// copy the assignment notebook bytes into the draft solution path so
    /// the instructor can author the answer key starting from the
    /// student-facing notebook.  Falls back to a blank notebook with the
    /// title suffix " Solution" when the assignment notebook isn't
    /// readable yet — same fallback the assignment-scoped variant uses.
    mutating func createSolutionFromAssignment() async throws {
        let sourceData: Data = {
            if let path = setup.notebookPath,
                let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                !bytes.isEmpty
            {
                return bytes
            }
            return defaultNotebookData(title: "\(notebookTitle) Solution")
        }()
        let normalized = normalizeNotebookForJupyterLite(sourceData)
        let path = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        try normalized.write(to: URL(fileURLWithPath: path))
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: setupID, userID: userID, fileKind: .solution),
            overwriteWith: normalized
        )
        formState.solutionNotebookName = "solution.ipynb"
    }

    mutating func uploadSolutionNotebook() async throws -> NewAssignmentDraftActionOutcome {
        guard let file = payload.solutionNotebookFile, file.data.readableBytes > 0 else {
            return .validationFailed("Select a solution notebook to upload")
        }
        let raw = Data(file.data.readableBytesView)
        guard (try? JSONSerialization.jsonObject(with: raw)) != nil else {
            return .validationFailed("Solution notebook must be valid JSON (.ipynb)")
        }
        let normalized = normalizeNotebookForJupyterLite(raw)
        let path = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        try normalized.write(to: URL(fileURLWithPath: path))
        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: setupID, userID: userID, fileKind: .solution),
            overwriteWith: normalized
        )
        formState.solutionNotebookName = notebookFilenameForStorage(
            uploadedName: file.filename, fallback: "solution.ipynb")

        // v0.4.100: auto-scan the solution for `##` sections and top-level
        // function defs, then scaffold one `publictest_exists_<fn>.py` per
        // detected function, placed in the section whose `##` header most
        // recently preceded it.  One-shot: silently skips if the manifest
        // already has sections / test entries.  Errors are swallowed —
        // this is a nice-to-have that must not block the upload.
        do {
            let result = try await autoScaffoldFromSolutionNotebook(
                setup: setup,
                notebookData: normalized,
                zipPath: setup.zipPath,
                on: req.db
            )
            if result.functions > 0 {
                req.logger.info(
                    "auto_scaffold sections=\(result.sections) functions=\(result.functions) setup=\(setup.id ?? "?")"
                )
            }
        } catch {
            req.logger.warning("auto_scaffold_failed setup=\(setup.id ?? "?") error=\(error)")
        }

        return .applied
    }

    mutating func clearSolutionNotebook() throws {
        removeDraftNotebookFiles(
            req: req,
            setupID: setupID,
            userID: userID,
            fileKind: .solution,
            persistedPath: draftSolutionNotebookPath(
                testSetupsDirectory: req.application.testSetupsDirectory, setupID: setupID)
        )
        formState.solutionNotebookName = nil
    }

    // MARK: - Suite-file actions

    mutating func replaceSuiteFiles() async throws {
        let setupPackage = try createRunnerSetupZip(
            suiteFiles: payload.suiteFiles,
            suiteConfigJSON: payload.suiteConfigRaw,
            zipPath: setup.zipPath
        )
        let sectionGradingMode = try await newAssignmentSectionGradingMode(
            req: req,
            courseID: courseID,
            sectionIDRaw: payload.sectionIDRaw
        )
        let starterNotebook =
            setup.notebookPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "assignment.ipynb"
        setup.manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile,
            gradingMode: sectionGradingMode,
            starterNotebook: starterNotebook
        )
        try await setup.save(on: req.db)
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: setupID,
            testSuiteScripts: Set(setupPackage.testSuites.map(\.script)),
            testSetupsDirectory: req.application.testSetupsDirectory
        )
    }

    mutating func clearSuiteFiles() async throws {
        let starterNotebook =
            setup.notebookPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "assignment.ipynb"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: setup.zipPath)
        setup.manifest = try makeWorkerManifestJSON(
            testSuites: [],
            includeMakefile: false,
            gradingMode: try await newAssignmentSectionGradingMode(
                req: req, courseID: courseID, sectionIDRaw: payload.sectionIDRaw),
            starterNotebook: starterNotebook
        )
        try await setup.save(on: req.db)
    }
}

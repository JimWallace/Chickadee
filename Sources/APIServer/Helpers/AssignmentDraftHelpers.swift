// APIServer/Helpers/AssignmentDraftHelpers.swift
//
// Draft-state types and helpers for the new-assignment authoring flow:
// session-stored form values, JupyterLite working-copy bookkeeping, and
// solution-notebook lookups.  Extracted from AssignmentHelpers.swift
// (issue #442). Moved below the routes to Helpers/ (#2142), because
// `NewAssignmentDraftService` and `NotebookWorkingCopyStore` call it.

import Core
import Fluent
import Foundation
import Vapor

/// Returned by `loadExistingSolution` with both the file data and the
/// original filename so the edit/save flow can re-submit with the correct name.
struct ExistingSolution {
    let data: Data
    let filename: String
}

struct NewAssignmentDraftFormState: Codable {
    var assignmentName: String
    var dueAt: String
    var startsAt: String
    var sectionID: String
    var requiredPlatform: String
    var requiredArchitecture: String
    var requiredLanguagesCSV: String
    var requiredCapabilitiesCSV: String
    var assignmentNotebookName: String?
    var solutionNotebookName: String?

    static let empty = NewAssignmentDraftFormState(
        assignmentName: "",
        dueAt: "",
        startsAt: "",
        sectionID: "",
        requiredPlatform: "",
        requiredArchitecture: "",
        requiredLanguagesCSV: "",
        requiredCapabilitiesCSV: "",
        assignmentNotebookName: nil,
        solutionNotebookName: nil
    )
}

struct DraftRequirementSuggestions {
    let languages: [String]
    let capabilities: [String]
}

func loadExistingSolution(req: Request, assignment: APIAssignment) async throws -> ExistingSolution? {
    try await loadExistingSolution(assignment: assignment, on: req.db)
}

/// The solution a validation run uses: the linked validation submission, or
/// failing that the newest one for the setup. Never a student submission, and
/// never the unvalidated draft (`SolutionSource.validationRuns`).
func loadExistingSolution(
    assignment: APIAssignment, on db: any Database
) async throws -> ExistingSolution? {
    // The two validation sources read no files under the setups directory.
    guard
        let found = try await resolveSolution(
            at: SolutionLocation(assignment), sources: SolutionSource.validationRuns, db: db,
            testSetupsDirectory: "")
    else { return nil }
    return ExistingSolution(data: found.data, filename: found.filename)
}

func existingSolutionFilename(req: Request, assignment: APIAssignment) async throws -> String? {
    try await existingSolutionFilename(assignment: assignment, on: req.db)
}

/// Database-only variant of `existingSolutionFilename(req:assignment:)`, for
/// callers that hold only a `Database` (the MCP tools).  Same resolution
/// order as `loadExistingSolution` above.
func existingSolutionFilename(assignment: APIAssignment, on db: any Database) async throws -> String? {
    if let validationID = assignment.validationSubmissionID,
        let validationSubmission = try await APISubmission.find(validationID, on: db)
    {
        return validationSubmission.filename ?? "solution.ipynb"
    }

    if let fallbackSubmission = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first()
    {
        return fallbackSubmission.filename ?? "solution.ipynb"
    }

    return nil
}

/// Whether the assignment has a reference solution on file: the fields that
/// record a validation run, or any source `resolveSolution` searches, the
/// unvalidated draft included. Shared by the workbench's Solution-tab gate and
/// the solution-visibility enable guard, and it uses the same sources as the
/// reveal page and `get_solution` (`SolutionSource.any`), so "there is a
/// solution" has one answer everywhere it is asked (#2488).
func assignmentHasSolution(
    assignment: APIAssignment, db: any Database, testSetupsDirectory: String
) async throws -> Bool {
    if assignment.validationStatus == "passed" || assignment.validationSubmissionID != nil {
        return true
    }
    return try await resolveSolution(
        at: SolutionLocation(assignment), sources: SolutionSource.any, db: db,
        testSetupsDirectory: testSetupsDirectory) != nil
}

private func draftFormStateSessionKey(_ draftID: String) -> String {
    "newAssignmentDraft:\(draftID)"
}

func loadDraftFormState(req: Request, draftID: String) -> NewAssignmentDraftFormState {
    guard let raw = req.session.data[draftFormStateSessionKey(draftID)],
        let data = raw.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(NewAssignmentDraftFormState.self, from: data)
    else {
        return .empty
    }
    return decoded
}

func saveDraftFormState(req: Request, draftID: String, state: NewAssignmentDraftFormState) {
    guard let data = try? JSONEncoder().encode(state),
        let raw = String(data: data, encoding: .utf8)
    else {
        return
    }
    req.session.data[draftFormStateSessionKey(draftID)] = raw
}

func clearDraftFormState(req: Request, draftID: String) {
    req.session.data[draftFormStateSessionKey(draftID)] = nil
}

private func draftNotebookDirectory(testSetupsDirectory: String, setupID: String) -> String {
    testSetupsDirectory + "notebooks/\(setupID)/"
}

func draftSolutionNotebookPath(testSetupsDirectory: String, setupID: String) -> String {
    draftNotebookDirectory(testSetupsDirectory: testSetupsDirectory, setupID: setupID) + "solution.ipynb"
}

func ensureDraftNotebookDirectory(testSetupsDirectory: String, setupID: String) throws -> String {
    let dir = draftNotebookDirectory(testSetupsDirectory: testSetupsDirectory, setupID: setupID)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func draftNotebookData(
    req: Request,
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind,
    fallbackPath: String?
) -> Data? {
    // The template copy first: on a personalized assignment it is the view the
    // author is actually working in, and it is the one holding `{{name}}`
    // rather than one person's values — which is what a draft must carry
    // forward.  On an assignment without personalization it simply does not
    // exist, and this falls through to the copy it always read.
    let candidatePaths = [NotebookViewMode.template, .personalized].map { viewMode in
        req.application.directory.publicDirectory + "jupyterlite/files/"
            + userNotebookWorkingCopyRelativePath(
                setupID: setupID, userID: userID, fileKind: fileKind, viewMode: viewMode)
    }
    for path in candidatePaths {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            !data.isEmpty,
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return data
        }
    }
    guard let fallbackPath,
        let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
        !data.isEmpty,
        (try? JSONSerialization.jsonObject(with: data)) != nil
    else {
        return nil
    }
    return data
}

func removeDraftNotebookFiles(
    application: Application,
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind,
    persistedPath: String?
) {
    let workingCopyPath =
        application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
    try? FileManager.default.removeItem(atPath: workingCopyPath)
    if let persistedPath {
        try? FileManager.default.removeItem(atPath: persistedPath)
    }
}

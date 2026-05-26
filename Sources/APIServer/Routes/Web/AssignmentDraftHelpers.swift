// APIServer/Routes/Web/AssignmentDraftHelpers.swift
//
// Draft-state types and helpers for the new-assignment authoring flow:
// session-stored form values, JupyterLite working-copy bookkeeping, and
// solution-notebook lookups.  Extracted from AssignmentHelpers.swift
// (issue #442) — no behaviour changes.

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
    if let validationID = assignment.validationSubmissionID,
        let validationSubmission = try await APISubmission.find(validationID, on: req.db),
        let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
        !data.isEmpty
    {
        return ExistingSolution(
            data: data,
            filename: validationSubmission.filename ?? "solution.ipynb"
        )
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first(),
        let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
        !data.isEmpty
    {
        return ExistingSolution(
            data: data,
            filename: fallbackSubmission.filename ?? "solution.ipynb"
        )
    }

    return nil
}

func existingSolutionFilename(req: Request, assignment: APIAssignment) async throws -> String? {
    if let validationID = assignment.validationSubmissionID,
        let validationSubmission = try await APISubmission.find(validationID, on: req.db)
    {
        return validationSubmission.filename ?? "solution.ipynb"
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first()
    {
        return fallbackSubmission.filename ?? "solution.ipynb"
    }

    return nil
}

func draftFormStateSessionKey(_ draftID: String) -> String {
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

func draftNotebookDirectory(testSetupsDirectory: String, setupID: String) -> String {
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
    let workingCopyPath =
        req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
    if let data = try? Data(contentsOf: URL(fileURLWithPath: workingCopyPath)),
        !data.isEmpty,
        (try? JSONSerialization.jsonObject(with: data)) != nil
    {
        return data
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
    req: Request,
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind,
    persistedPath: String?
) {
    let workingCopyPath =
        req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
    try? FileManager.default.removeItem(atPath: workingCopyPath)
    if let persistedPath {
        try? FileManager.default.removeItem(atPath: persistedPath)
    }
}

// APIServer/Services/AuthoringDraft.swift
//
// Staff authoring drafts on the server-backed editor drive (#2925). The rule is
// in `AuthoringDraftFiles`; this file finds the seed and the base for a draft.
//
// The base lives outside the working-copy tree, under the test-setups
// directory, so neither the editor nor the kernel can see or write it, and it
// is on the same persistent volume as the drafts.

import Core
import Fluent
import Foundation
import SystemPackage
import Vapor

/// The base file for the working copy at `relativePath`
/// (`users/<id>/<setupID>/<file>.ipynb`).
func authoringDraftBasePath(relativePath: String, application: Application) -> String {
    application.testSetupsDirectory + "authoring-draft-bases/" + relativePath
}

/// Opens a staff draft for the editor: seeds it, keeps it, refreshes it from
/// the stored notebook, or keeps its unpublished edits in a dated backup beside
/// it (`AuthoringDraftFiles.reconcile`).
func ensureAuthoringDraft(
    _ source: WorkingCopySeedSource,
    relativePath: String,
    on db: any Database,
    application: Application,
    logger: Logger
) async throws -> AuthoringDraftOutcome {
    let seed = try await workingCopySeedData(source, on: db, application: application, logger: logger)
    let setupID = source.setupID
    let userID = source.userID
    let fallbackSetup = source.setup
    let draftPath = application.directory.publicDirectory + "jupyterlite/files/" + relativePath
    let basePath = authoringDraftBasePath(relativePath: relativePath, application: application)
    let outcome = try await runBlocking {
        try AuthoringDraftFiles.reconcile(
            draftPath: draftPath, basePath: basePath, seed: seed, now: Date(), same: sameDraftContent)
    }
    if case .backedUp(let fileName) = outcome {
        logger.info("authoring_draft_backed_up setup=\(setupID) user=\(userID.uuidString) backup=\(fileName)")
    }
    let draftDirectory = FilePath(draftPath).removingLastComponent().string
    await createSupportFileSymlinks(setup: fallbackSetup, studentDir: draftDirectory, application: application)
    await writeDatasetFiles(
        setup: fallbackSetup, userID: userID, studentDir: draftDirectory, on: db, application: application)
    return outcome
}

/// Records that the draft at `relativePath` is in sync with the stored notebook
/// as it is now (after "Save to assignment").
func recordAuthoringDraftBase(
    _ source: WorkingCopySeedSource,
    relativePath: String,
    on db: any Database,
    application: Application,
    logger: Logger
) async throws {
    let seed = try await workingCopySeedData(source, on: db, application: application, logger: logger)
    let basePath = authoringDraftBasePath(relativePath: relativePath, application: application)
    try await runBlocking { try AuthoringDraftFiles.recordBase(seed, at: basePath) }
}

/// True when the working copy at `relativePath` already holds `normalized` (a
/// notebook passed through `normalizeNotebookForJupyterLite`) as a document.
/// The copy is normalized the same way first: JupyterLab saves the kernel
/// metadata as the running kernel reports it, which normalization rewrites, so
/// comparing the raw file would call the same notebook different.
func workingCopyHolds(_ normalized: Data, relativePath: String, application: Application) async throws -> Bool {
    let path = application.directory.publicDirectory + "jupyterlite/files/" + relativePath
    let existing = try await runBlocking { try? Data(contentsOf: URL(fileURLWithPath: path)) }
    guard let existing else { return false }
    return sameDraftContent(existing, normalized)
}

/// Two notebooks are the same draft when they hold the same authored
/// content. What running the kernel adds is not an edit: the notebook's
/// `kernelspec` and `language_info` (JupyterLab rewrites them on save), and
/// each cell's outputs, execution count and execution timing. Running an
/// unedited draft must not back it up as unpublished work.
func sameDraftContent(_ lhs: Data, _ rhs: Data) -> Bool {
    if lhs == rhs { return true }
    guard let left = authoredNotebookContent(lhs), let right = authoredNotebookContent(rhs) else {
        return sameNotebookContent(lhs, rhs)
    }
    return left == right
}

/// `data` as a notebook with the kernel-derived fields removed
/// (`sameDraftContent`), or nil when it is not a notebook object. An empty
/// metadata object counts as an absent one.
private func authoredNotebookContent(_ data: Data) -> [String: JSONValue]? {
    guard var notebook = JSONValue.object(from: data) else { return nil }
    if var metadata = notebook["metadata"]?.objectValue {
        metadata["kernelspec"] = nil
        metadata["language_info"] = nil
        notebook["metadata"] = metadata.isEmpty ? nil : .object(metadata)
    }
    if let cells = notebook["cells"]?.arrayValue {
        notebook["cells"] = .array(
            cells.map { cell in
                guard let original = cell.objectValue else { return cell }
                // The same clearing the stored starter gets (`NotebookOutputs`).
                var fields = NotebookOutputs.clearingRunState(original)
                if fields["metadata"]?.objectValue?.isEmpty == true {
                    fields["metadata"] = nil
                }
                return .object(fields)
            })
    }
    return notebook
}

/// The newest backup of the draft at `relativePath` from the last 14 days,
/// for the page to link (#2925).
func recentAuthoringDraftBackup(relativePath: String, application: Application) async -> String? {
    let draftPath = application.directory.publicDirectory + "jupyterlite/files/" + relativePath
    let since = Date().addingTimeInterval(-14 * 24 * 60 * 60)
    return try? await runBlocking { AuthoringDraftFiles.newestBackup(draftPath: draftPath, since: since) }
}

/// Keeps the draft at `relativePath` in a dated backup before a write replaces
/// it, and returns the backup's name.
func backUpAuthoringDraft(relativePath: String, application: Application) async throws -> String? {
    let draftPath = application.directory.publicDirectory + "jupyterlite/files/" + relativePath
    return try await runBlocking { try AuthoringDraftFiles.backUp(draftPath: draftPath, now: Date()) }
}

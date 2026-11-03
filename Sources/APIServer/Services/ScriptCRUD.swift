// APIServer/Services/ScriptCRUD.swift
//
// Shared cores for creating and deleting individual test/support scripts inside
// a test setup's zip + manifest. Used by both the published
// (`PublishedAssignmentRoutes+ScriptCRUD`) and draft
// (`DraftAssignmentRoutes+SuiteEditing`) handlers — which differ only in how
// they resolve the target setup and what they do afterward (the published path
// re-extracts support files to the shared student dir and returns an editURL; a
// draft has no students or stable route yet, so it does neither).

import Core
import Fluent
import Foundation
import Vapor

/// Decoded request body for the create-script endpoints (published + draft).
struct CreateScriptBody: Content {
    var filename: String
    var content: String
    var tier: String?
    var points: Int?
    var isTest: Bool?
}

/// The resolved outcome of a create, used by the caller to shape its response
/// and decide on support-file re-extraction.
struct CreatedScript {
    let filename: String
    let tier: String
    let points: Int
    let isTest: Bool
}

/// Validates the filename, inlines assignment-scope variables, writes the file
/// into the setup zip, and — for a graded tier — adds a manifest entry.
@discardableResult
func createScriptInSetup(
    setup: APITestSetup,
    body: CreateScriptBody,
    kernelEnvironments: KernelEnvironments? = nil,
    on db: any Database
) async throws -> CreatedScript {
    let cleaned = sanitizeSuiteFilename(body.filename)
    guard !cleaned.isEmpty, cleaned == body.filename else {
        throw AppError.invalidParameter(name: "filename", reason: "Invalid filename '\(body.filename)'")
    }

    // Reject duplicate filenames.
    if await listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
        throw AppError.conflict(reason: "A file named '\(cleaned)' already exists in this setup")
    }

    // Slice 1: prepend assignment-scope variables before write so the saved
    // content matches what the runner sees. Section variables aren't applied
    // here (the suite entry — and thus its sectionID — is created below); the
    // next applyPatternFamilies / suite-edit save re-prepends with section
    // scope. Falls back to raw content for non-.py files or a bad manifest.
    let inlined: String = {
        guard let manifest = setup.decodedManifest() else { return body.content }
        return TestScriptVariablePrepender.applyForRawScript(
            filename: cleaned, content: body.content, manifest: manifest)
    }()
    // Refuse a browser-graded Python script whose imports the grading kernel
    // cannot satisfy — checked on the INLINED text, since that is what runs.
    try await KernelImportGuard.check(
        filename: cleaned, content: inlined, setup: setup, environments: kernelEnvironments)
    try await updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: inlined)

    // Whether the file is a test is the server's call when the caller does not
    // say. The suite table's upload says nothing: its browser-side guess had a
    // stale extension list and filed Lua, Octave, Racket and Java tests as
    // support files (#1960). A caller that names a tier or `isTest` still
    // decides.
    let isTest =
        body.isTest
        ?? (body.tier == nil ? isLikelyTestSuiteScript(name: cleaned, leadingText: body.content) : nil)
    let tier = normalizeTier(body.tier, isTest: isTest)
    // v0.4.105: allow 0-mark tests (e.g. function-existence guards that only
    // short-circuit downstream tests). Negative values clamp to 0.
    let points = max(0, body.points ?? 1)
    let shouldTest = tier != "support"

    if shouldTest {
        let entry = ConfiguredSuiteEntry(
            script: cleaned, tier: tier, order: 0,
            dependsOn: [], points: points, displayName: nil)
        // Conditional, and applied again to a newer manifest if another edit
        // saved first, so that edit is kept (#2485).
        try await mutateManifestJSON(setup: setup, on: db) {
            updateManifestAddingScript(manifestJSON: $0, entry: entry)
        }
    }

    return CreatedScript(filename: cleaned, tier: tier, points: points, isTest: shouldTest)
}

/// The web door to `deleteFileFromSetup` (`SetupFileDeletion.swift`), which
/// MCP `delete_support_file` calls too (#2771). It words each refusal as the
/// web routes always have.
func deleteScriptFromSetup(setup: APITestSetup, filename: String, on db: any Database) async throws {
    do {
        try await deleteFileFromSetup(setup: setup, filename: filename, on: db)
    } catch SetupFileDeletionError.notInSetup(let file) {
        throw AppError.notFound(resource: "File '\(file)' in setup zip")
    } catch SetupFileDeletionError.generatedByFamily(let file, let familyID) {
        throw AppError.conflict(
            reason:
                "'\(file)' is generated from pattern family '\(familyID)'. Remove it via the family editor (delete the case, or delete the whole family)."
        )
    } catch SetupFileDeletionError.libraryAttached(let refusal) {
        throw AppError.conflict(reason: refusal)
    } catch SetupFileDeletionError.hasDependents(let file, let dependents) {
        throw AppError.conflict(
            reason:
                "Cannot delete '\(file)': the following scripts depend on it: \(dependents.joined(separator: ", "))"
        )
    } catch SetupFileDeletionError.zipUpdateFailed {
        throw AppError.internalFailure(reason: "Failed to update setup zip")
    }
}

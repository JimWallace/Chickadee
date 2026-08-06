// APIServer/Routes/Web/ScriptCRUDHelpers.swift
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
        throw WebAssignmentError.invalidParameter(name: "filename", reason: "Invalid filename '\(body.filename)'")
    }

    // Reject duplicate filenames.
    if listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
        throw WebAssignmentError.conflict(reason: "A file named '\(cleaned)' already exists in this setup")
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
    try KernelImportGuard.check(
        filename: cleaned, content: inlined, setup: setup, environments: kernelEnvironments)
    try updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: inlined)

    let tier = normalizeTier(body.tier, isTest: body.isTest)
    // v0.4.105: allow 0-mark tests (e.g. function-existence guards that only
    // short-circuit downstream tests). Negative values clamp to 0.
    let points = max(0, body.points ?? 1)
    let shouldTest = tier != "support"

    if shouldTest {
        let entry = ConfiguredSuiteEntry(
            script: cleaned, tier: tier, order: 0,
            dependsOn: [], points: points, displayName: nil)
        if let updated = updateManifestAddingScript(manifestJSON: setup.manifest, entry: entry) {
            setup.manifest = updated
            try await setup.save(on: db)
        }
    }

    return CreatedScript(filename: cleaned, tier: tier, points: points, isTest: shouldTest)
}

/// Guards that the file exists and is neither pattern-family-generated nor a
/// prerequisite of another script, then removes it from the setup zip and drops
/// its manifest entry.
func deleteScriptFromSetup(setup: APITestSetup, filename: String, on db: any Database) async throws {
    guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
        throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
    }

    if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
        throw WebAssignmentError.conflict(
            reason:
                "'\(filename)' is generated from pattern family '\(familyID)'. Remove it via the family editor (delete the case, or delete the whole family)."
        )
    }

    let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
    guard dependents.isEmpty else {
        throw WebAssignmentError.conflict(
            reason:
                "Cannot delete '\(filename)': the following scripts depend on it: \(dependents.joined(separator: ", "))"
        )
    }

    do {
        try removeScriptFromZip(zipPath: setup.zipPath, filename: filename)
    } catch ScriptZipError.zipFailed {
        throw WebAssignmentError.internalFailure(reason: "Failed to update setup zip")
    }

    if let updated = updateManifestRemovingScript(manifestJSON: setup.manifest, filename: filename) {
        setup.manifest = updated
        try await setup.save(on: db)
    }
}

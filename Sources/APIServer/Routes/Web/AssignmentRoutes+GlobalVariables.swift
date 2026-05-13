// APIServer/Routes/Web/AssignmentRoutes+GlobalVariables.swift
//
// Slice 1 — assignment-scope global variables.  GET returns the current
// list; PUT replaces it atomically.  PUT triggers a full
// `applyPatternFamilies` re-render so:
//   - pattern-family-generated test scripts get the new global values
//     inlined alongside section + family variables;
//   - raw instructor-uploaded `.py` test scripts get re-prepended with
//     the new scope;
//   - the manifest hash bumps, which the v0.4.93 retest fan-out picks
//     up to re-grade existing submissions.
//
// Validation:
//   - each `name` must be a valid Python identifier;
//   - `seed` is reserved (claimed by Slice 2 personalization);
//   - no duplicate names within global;
//   - no duplicate names against any section variable (same effective
//     namespace at inline time);
//   - the assignment's starter notebook is scanned for `{{name}}`
//     markers — any name that isn't declared in global OR section
//     variables surfaces as a 400 listing the unknown markers.
//
// On success: 200 OK + JSON body with the reconciled list and any
// non-blocking warnings (currently unused; reserved for future
// non-fatal feedback like shadowing a Python builtin).

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    private static let reservedGlobalNames: Set<String> = ["seed"]

    struct GlobalVariablesBody: Content {
        var variables: [FamilyVariable]
    }

    struct GlobalVariablesResponse: Content {
        var variables: [FamilyVariable]
        var warnings: [String]
    }

    // MARK: - GET /instructor/:assignmentID/global-variables

    @Sendable
    func getGlobalVariables(req: Request) async throws -> GlobalVariablesResponse {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)

        let manifest = try decodeManifest(setup: setup)
        return GlobalVariablesResponse(
            variables: manifest.globalVariables,
            warnings: []
        )
    }

    // MARK: - PUT /instructor/:assignmentID/global-variables

    @Sendable
    func putGlobalVariables(req: Request) async throws -> GlobalVariablesResponse {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(GlobalVariablesBody.self)

        let manifest = try decodeManifest(setup: setup)

        // 1. Per-row + cross-list validation.
        var seenNames: Set<String> = []
        for v in body.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Global variable name '\(v.name)' is not a valid Python identifier.")
            }
            guard !Self.reservedGlobalNames.contains(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "'\(v.name)' is reserved for Chickadee's personalization seed. " +
                            "Choose another name.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate global variable name '\(v.name)'.")
            }
        }

        // Cross-list: no clash with any section variable name (same effective
        // Python namespace at inline time, so duplicates would shadow
        // unpredictably).
        for section in manifest.sections {
            for sv in section.variables {
                guard !seenNames.contains(sv.name) else {
                    throw WebAssignmentError.unprocessable(
                        reason: "Global variable name '\(sv.name)' is already used by " +
                                "section '\(section.name)'. Section and global names share a " +
                                "namespace; rename one to avoid shadowing.")
                }
            }
        }

        // 2. Starter-notebook `{{undeclared}}` scan.  Combine the new
        // global list with all section variables to form the declared
        // name set, then check every `{{name}}` marker in the starter
        // notebook for membership.  Unknown markers fail the save.
        var declared: Set<String> = seenNames
        for section in manifest.sections {
            for sv in section.variables { declared.insert(sv.name) }
        }
        if let starterName = manifest.starterNotebook,
           let notebookData = extractZipEntry(zipPath: setup.zipPath,
                                              entryName: starterName) {
            let used = NotebookSubstitution.placeholderNames(in: notebookData)
            let unknown = used.filter { !declared.contains($0) }
            if !unknown.isEmpty {
                let list = unknown.map { "{{\($0)}}" }.joined(separator: ", ")
                throw WebAssignmentError.unprocessable(
                    reason: "Starter notebook references unknown placeholder(s): \(list). " +
                            "Declare them as global or section inputs first.")
            }
        }

        // 3. Re-render through `applyPatternFamilies` so generated tests
        // inline the new globals and raw `.py` scripts get re-prepended.
        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: manifest.patternFamilies,
            nextChecks: manifest.notebookChecks,
            authoredItems: nil,                         // carry forward authored order
            sections: manifest.sections,                // unchanged
            globalVariables: body.variables,            // the new list
            on: req.db
        )

        // 4. Re-load the persisted manifest so the response reflects the
        // reconciled state (in particular, any decode-round-trip
        // normalisation we don't replay locally).
        let updatedManifest = try decodeManifest(setup: setup)
        return GlobalVariablesResponse(
            variables: updatedManifest.globalVariables,
            warnings: []
        )
    }

    // MARK: - helpers

    private func decodeManifest(setup: APITestSetup) throws -> TestProperties {
        guard let data = setup.manifest.data(using: .utf8),
              let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
        else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }
        return manifest
    }
}

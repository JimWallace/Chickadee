// APIServer/Utilities/PatternFamilyApplication.swift
//
// Applies a list of PatternFamily specs to an APITestSetup: diffs old vs
// new families, mutates the zip (add/update/delete generated `.py` files),
// and rewrites the manifest JSON to reflect the new spec + expanded
// TestSuiteEntries.
//
// The runner's cache key includes the manifest bytes, so updating the
// manifest here is what causes runners to fetch a fresh copy after a family
// edit — there is no separate bust-the-cache step.

import Foundation
import Core
import Vapor
import Fluent

/// Outcome of applying a new family list, useful for logging / tests.
struct PatternFamilyApplyResult: Equatable {
    let writtenFiles:  [String]   // filenames added or overwritten in the zip
    let deletedFiles:  [String]   // filenames removed from the zip
    let manifestBefore: String    // manifest JSON before the change
    let manifestAfter:  String    // manifest JSON after the change
}

/// Validates `nextFamilies`, computes a diff against the families currently
/// recorded in `setup.manifest`, applies the diff to the zip, and rewrites
/// the manifest.  On success, persists the updated manifest to the database.
///
/// - Returns: a `PatternFamilyApplyResult` describing the zip mutations.
/// - Throws: `Abort(.unprocessableEntity)` on validation failure (in which
///   case neither the zip nor the manifest is modified), or the underlying
///   error from zip or database operations.
@discardableResult
func applyPatternFamilies(
    to setup: APITestSetup,
    nextFamilies: [PatternFamily],
    on db: Database
) async throws -> PatternFamilyApplyResult {

    let oldManifest = setup.manifest
    guard let data = oldManifest.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        throw Abort(.internalServerError, reason: "Test setup manifest is not valid JSON")
    }

    // 1. Validate new family list against the raw-script portion of the
    //    existing manifest (hand-written entries are preserved verbatim).
    try validatePatternFamilies(nextFamilies, testSuites: props.testSuites)

    // 2. Diff old vs new generated filenames.
    let oldGeneratedFilenames = Set(
        props.patternFamilies.flatMap(patternFamilyAllGeneratedFilenames)
    )

    var renderedByFilename: [String: GeneratedScript] = [:]
    for family in nextFamilies {
        for generated in renderPatternFamily(family) {
            renderedByFilename[generated.filename] = generated
        }
    }
    let newGeneratedFilenames = Set(renderedByFilename.keys)

    let toDelete = oldGeneratedFilenames.subtracting(newGeneratedFilenames)
    let toWrite  = renderedByFilename.mapValues(\.source)

    // 3. Apply the zip mutations.  This is a single extract-repack cycle.
    try applyScriptChangesToZip(
        zipPath: setup.zipPath,
        writes: toWrite,
        deletions: Array(toDelete)
    )

    // 4. Build the new testSuites list: preserve raw (generatedBy == nil)
    //    entries in their original order, then append entries for each
    //    rendered case in a stable family/case order.  Generated entries
    //    added for the first time have no `dependsOn`; re-applied ones
    //    preserve any dependsOn the instructor had previously declared.
    let oldEntryByScript: [String: TestSuiteEntry] = Dictionary(
        uniqueKeysWithValues: props.testSuites.map { ($0.script, $0) }
    )
    var newConfigured: [ConfiguredSuiteEntry] = []

    // (a) raw entries, preserving relative order.
    var order = 0
    for e in props.testSuites where e.generatedBy == nil {
        order += 1
        newConfigured.append(ConfiguredSuiteEntry(
            script:      e.script,
            tier:        e.tier.rawValue,
            order:       order,
            dependsOn:   e.dependsOn.filter { !toDelete.contains($0) },
            points:      e.points,
            displayName: e.name,
            generatedBy: nil
        ))
    }
    // (b) generated entries, stable ordering across families then cases.
    for family in nextFamilies {
        for generated in renderPatternFamily(family) {
            order += 1
            let prior = oldEntryByScript[generated.filename]
            newConfigured.append(ConfiguredSuiteEntry(
                script:      generated.filename,
                tier:        generated.tier.rawValue,
                order:       order,
                dependsOn:   prior?.dependsOn.filter { !toDelete.contains($0) } ?? [],
                points:      generated.points,
                displayName: generated.displayName,
                generatedBy: generated.familyID
            ))
        }
    }

    let newManifest = try makeWorkerManifestJSON(
        testSuites:      newConfigured,
        includeMakefile: props.makefile != nil,
        gradingMode:     props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: nextFamilies
    )

    setup.manifest = newManifest
    try await setup.save(on: db)

    return PatternFamilyApplyResult(
        writtenFiles:   Array(toWrite.keys).sorted(),
        deletedFiles:   Array(toDelete).sorted(),
        manifestBefore: oldManifest,
        manifestAfter:  newManifest
    )
}

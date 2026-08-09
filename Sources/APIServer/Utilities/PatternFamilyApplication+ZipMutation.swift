// APIServer/Utilities/PatternFamilyApplication+ZipMutation.swift
//
// Phase 4 of `applyPatternFamilies`: render every generated artifact exactly
// once, diff the result against what the previous manifest generated, and
// apply both the writes and the deletions to the setup zip in one pass.
//
// Split out of PatternFamilyApplication.swift (#1253).  Unlike phase 5 this
// one has a side effect — it mutates the zip — so it is not a pure function;
// what makes it separable is that every decision feeding it is already made,
// and nothing after it needs anything from it beyond the four values in
// `AppliedZipMutations`.

import Core
import Foundation

/// Everything the render-and-write phase needs.
///
/// This is a parameter object rather than a nine-argument function because the
/// repo's `function_parameter_count` ceiling is six — and because bundling the
/// arguments that travel together is the point, not a workaround for the lint
/// rule.
struct GeneratedArtifactPlan {
    let families: [PatternFamily]
    let checks: [NotebookCheck]
    /// familyID → sectionID, built once by the caller and shared with the
    /// validator so the two cannot disagree about where a family lives.
    let familySectionID: [String: String]
    let sections: [TestSuiteSection]
    let globalVariables: [FamilyVariable]
    let perStudentNames: Set<String>
    let itemsForOrdering: [AuthoredSuiteItem]
    let language: AssignmentLanguage
    /// The language the *previous* manifest was written in, if it had one.
    let previousLanguage: AssignmentLanguage?
}

/// What phase 4 produced, and what the phases after it consume.
struct AppliedZipMutations {
    /// Rendered once here; the manifest rebuild consumes these same values, so
    /// the entries it writes describe exactly the bytes that went into the zip.
    let artifacts: RenderedFamilyArtifacts
    let renderedCheckByID: [String: GeneratedScript]
    let writtenFilenames: [String]
    let deletedFilenames: Set<String>
}

/// Renders families and notebook checks, computes the add/delete diff against
/// the previous manifest's generated filenames, and applies both to the zip.
func renderAndApplyZipMutations(
    plan: GeneratedArtifactPlan,
    previousProps: TestProperties,
    zipPath: String
) throws -> AppliedZipMutations {
    // Old-side filenames for both generators are pooled into one set so
    // the deletion diff is computed in one shot.  Notebook checks may
    // produce sidecar files (e.g. `_expected_<id>.csv` for
    // `.dataFrameEquality`); both the script and the sidecars are
    // tracked here so removing a check cleans up all of its files.
    // The generated extension is part of the filename, so the old files must be
    // listed under the language the *previous* manifest was written in — and,
    // when the assignment changes language, under the new one too, or the
    // old-extension scripts would be stranded in the setup forever. Listing
    // only these two keeps `deletedFiles` free of names that were never written.
    // `previousLanguage` is optional (an assignment that had no language yet),
    // so the pair is built explicitly rather than as a set literal — which also
    // keeps the two comprehensions below inside the type-checker's budget.
    var oldFilenameLanguages: Set<AssignmentLanguage> = [plan.language]
    if let previousLanguage = plan.previousLanguage {
        oldFilenameLanguages.insert(previousLanguage)
    }
    let oldGeneratedFilenames = Set(
        oldFilenameLanguages.flatMap { language in
            previousProps.patternFamilies.flatMap {
                patternFamilyAllGeneratedFilenames($0, language: language)
            }
        }
    ).union(
        oldFilenameLanguages.flatMap { language in
            previousProps.notebookChecks.flatMap {
                notebookCheckAllGeneratedFilenames($0, language: language)
            }
        }
    )

    // A family whose id is missing from `familySectionID` (the defensive path
    // in the entry builder) renders with no section variables — matching its
    // "unanchored" status.
    let sectionVarsByID: [String: [FamilyVariable]] = Dictionary(
        uniqueKeysWithValues: plan.sections.map { ($0.id, $0.variables) }
    )
    // Every family renders exactly once, here.  Both the zip write below
    // and the manifest rebuild consume these artifacts — the manifest phase
    // used to invoke the renderer a second time per family, which wasted work
    // and meant a renderer that ever became non-deterministic would silently
    // desync the zip bytes from the manifest entries (#1123).
    let artifacts = renderFamilyArtifacts(
        families: plan.families,
        familySectionID: plan.familySectionID,
        sectionVarsByID: sectionVarsByID,
        globalVariables: plan.globalVariables,
        perStudentNames: plan.perStudentNames,
        language: plan.language
    )

    var renderedByFilename: [String: GeneratedScript] = [:]
    for family in plan.families {
        for generated in artifacts.caseScripts[family.id] ?? [] {
            renderedByFilename[generated.filename] = generated
        }
        if let guardScript = artifacts.guardScripts[family.id] {
            renderedByFilename[guardScript.filename] = guardScript
        }
    }
    // Render notebook checks alongside pattern families so a single zip
    // mutation pass writes everything.  Each check produces one script
    // file plus zero or more sidecar files (e.g. `_expected_<id>.csv`
    // for `.dataFrameEquality`).  Sidecars don't have a `GeneratedScript`
    // — they aren't entries in the suite — but they DO need to be in
    // `newGeneratedFilenames` so stale ones get diffed away when a check
    // changes kind or is removed.
    var renderedCheckByID: [String: GeneratedScript] = [:]
    var sidecarFilesToWrite: [String: String] = [:]
    for check in plan.checks {
        let bundle = renderNotebookCheck(check, language: plan.language)
        renderedByFilename[bundle.script.filename] = bundle.script
        renderedCheckByID[check.id] = bundle.script
        for (name, content) in bundle.sidecars {
            sidecarFilesToWrite[name] = content
        }
    }
    let newGeneratedFilenames = Set(renderedByFilename.keys)
        .union(sidecarFilesToWrite.keys)

    let toDelete = oldGeneratedFilenames.subtracting(newGeneratedFilenames)
    // Merge generated sources with check sidecars (e.g. expected CSVs) into
    // the single write map.  applyScriptChangesToZip is bytes-agnostic — it
    // doesn't care that some entries are scripts and others are CSV.
    var toWrite = renderedByFilename.mapValues(\.source)
    for (name, content) in sidecarFilesToWrite {
        toWrite[name] = content
    }

    // Re-inline global + section variables into every raw (non-generated)
    // test script (idempotent; see the helper).
    for (filename, content) in rawScriptOverlayWrites(
        items: plan.itemsForOrdering,
        generatedFilenames: Set(renderedByFilename.keys),
        zipPath: zipPath,
        globalVariables: plan.globalVariables,
        sectionVarsByID: sectionVarsByID
    ) {
        toWrite[filename] = content
    }

    try applyScriptChangesToZip(
        zipPath: zipPath,
        writes: toWrite,
        deletions: Array(toDelete)
    )

    return AppliedZipMutations(
        artifacts: artifacts,
        renderedCheckByID: renderedCheckByID,
        writtenFilenames: Array(toWrite.keys).sorted(),
        deletedFilenames: toDelete
    )
}

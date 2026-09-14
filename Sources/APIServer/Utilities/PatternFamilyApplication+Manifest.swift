// APIServer/Utilities/PatternFamilyApplication+Manifest.swift
//
// Phase 6 of `applyPatternFamilies`: rebuild the manifest JSON from the newly
// ordered suite entries and re-validate the result.
//
// Split out of PatternFamilyApplication.swift (#1253).

import Core
import Foundation

/// Rebuilds the manifest and re-checks the post-expansion result.
///
/// The base `makeWorkerManifestJSON` builds a fresh dictionary, so anything
/// not threaded through is lost — the failure mode this phase was most prone
/// to. The `preserving:` overload carries every field of the previous
/// manifest forward by default, so only what this phase actually recomputes
/// is passed.
func rebuildPatternFamilyManifest(
    entries: [ConfiguredSuiteEntry],
    previousProps props: TestProperties,
    families: [PatternFamily],
    inputs: ResolvedApplyInputs,
    language: AssignmentLanguage?
) throws -> String {
    let newManifest = try makeWorkerManifestJSON(
        preserving: props,
        testSuites: entries,
        patternFamilies: families,
        notebookChecks: inputs.checks,
        sections: inputs.sections,
        globalVariables: inputs.globalVariables,
        globalExpressions: inputs.globalExpressions,
        // Always record the language the author DECLARED, Python included —
        // and nil when they declared none. An explicit answer is the point: a
        // suite that later holds only pattern families has no `.R` script left
        // to sniff, and "we inferred Python" and "this is a Python assignment"
        // should not be the same state. This used to be handed a non-optional
        // that had already been `?? .python`'d, so reordering two `.sh`
        // scripts on an assignment whose author chose "None" rewrote its
        // declaration to Python.
        language: language
    )

    // Belt-and-suspenders: the post-expansion manifest is the one the runner
    // will actually consume.  It must not contain any `family:<id>` tokens,
    // must reference only existing scripts, and must still be acyclic.
    if let postData = newManifest.data(using: .utf8),
        let postProps = decodeManifest(from: postData)
    {
        try validateManifestDependencies(postProps)
    }

    return newManifest
}

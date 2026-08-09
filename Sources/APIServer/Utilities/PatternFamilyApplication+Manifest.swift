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
/// `makeWorkerManifestJSON` builds a fresh dictionary, so **anything not
/// threaded through here is lost.** That is the failure mode this phase is
/// most prone to: `submissionMode`, `requiredFiles`, `minimumRunnerVersion`,
/// achievements and datasets are all carried forward explicitly for that
/// reason, and a new manifest field needs adding here as well as to the
/// encoder.
func rebuildPatternFamilyManifest(
    entries: [ConfiguredSuiteEntry],
    previousProps props: TestProperties,
    families: [PatternFamily],
    inputs: ResolvedApplyInputs,
    language: AssignmentLanguage
) throws -> String {
    let newManifest = try makeWorkerManifestJSON(
        testSuites: entries,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        submissionMode: props.submissionMode.rawValue,
        requiredFiles: props.requiredFiles,
        timeLimitSeconds: props.timeLimitSeconds,
        starterNotebook: props.starterNotebook,
        patternFamilies: families,
        notebookChecks: inputs.checks,
        sections: inputs.sections,
        globalVariables: inputs.globalVariables,
        globalExpressions: inputs.globalExpressions,
        achievements: props.achievements,
        disabledBuiltInAwardIDs: props.disabledBuiltInAwardIDs,
        builtInAchievementsSeeded: props.builtInAchievementsSeeded,
        datasets: props.datasets,
        // Always record the language, Python included. An explicit answer is
        // the point: a suite that later holds only pattern families has no
        // `.R` script left to sniff, and "we inferred Python" and "this is a
        // Python assignment" should not be the same state. The first save of
        // a pre-existing assignment therefore changes its manifest hash once,
        // which re-keys the runner's TestSetupCache and triggers one
        // revision-retest fan-out for that assignment — a bounded, one-time
        // cost accepted in exchange for the language never being re-inferred.
        language: language,
        minimumRunnerVersion: props.minimumRunnerVersion
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

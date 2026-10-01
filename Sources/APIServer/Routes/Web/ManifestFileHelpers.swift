// APIServer/Routes/Web/ManifestFileHelpers.swift
//
// Read, mutate, and serialize `TestProperties` manifest JSON: dependent
// lookups, generated-by checks, add/remove script entries, the worker-
// facing manifest builder, topological sort, and the hash used as the
// auto-retest dedup key.  Extracted from AssignmentHelpers.swift
// (issue #442) — no behaviour changes.

import Core
import Foundation
import Vapor

/// Returns the scripts in the manifest that list `filename` in their `dependsOn`.
func manifestDependents(manifestJSON: String, filename: String) -> [String] {
    guard let props = decodeManifest(fromJSON: manifestJSON)

    else {
        return []
    }
    return props.testSuites
        .filter { $0.dependsOn.contains(filename) }
        .map(\.script)
}

/// If the manifest entry for `filename` was produced by a pattern family,
/// returns that family id.  Returns nil for hand-written scripts or missing
/// entries.  Used by the raw-script edit/delete endpoints to reject edits
/// that must instead go through the family editor.
func generatedByFamilyID(manifestJSON: String, filename: String) -> String? {
    guard let props = decodeManifest(fromJSON: manifestJSON)

    else {
        return nil
    }
    return props.testSuites.first(where: { $0.script == filename })?.generatedBy
}

/// Returns true when the setup's manifest has at least one test entry
/// (raw script or generated-by-family).  Used by `saveEditedAssignment`
/// to refuse saving an empty suite.
func setupHasAnyTestEntries(manifestJSON: String) throws -> Bool {
    guard let props = decodeManifest(fromJSON: manifestJSON)

    else { return false }
    return !props.testSuites.isEmpty
}

/// Returns updated manifest JSON with a new `TestSuiteEntry` appended.
/// Preserves all existing entries (including their `sectionID`,
/// `generatedByCheck`, and `hint`), grading mode, makefile config,
/// starterNotebook, pattern families, notebook checks, the `sections`
/// list, and the assignment-scope global variables/expressions.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestAddingScript(
    manifestJSON: String,
    entry: ConfiguredSuiteEntry
) -> String? {
    guard let props = decodeManifest(fromJSON: manifestJSON)

    else {
        return nil
    }
    let existing = props.testSuites.enumerated().map { idx, e in ConfiguredSuiteEntry(e, order: idx + 1) }
    let nextOrder = (existing.map(\.order).max() ?? 0) + 1
    let newEntry = ConfiguredSuiteEntry(
        script: entry.script,
        tier: entry.tier,
        order: nextOrder,
        dependsOn: entry.dependsOn,
        points: entry.points,
        displayName: entry.displayName,
        generatedBy: entry.generatedBy,
        generatedByCheck: entry.generatedByCheck,
        sectionID: entry.sectionID,
        hint: entry.hint,
        timeLimitSeconds: entry.timeLimitSeconds
    )
    return try? makeWorkerManifestJSON(
        preserving: props, testSuites: existing + [newEntry], language: props.language)
}

/// Returns updated manifest JSON with the entry for `filename` removed.
/// Also clears references to `filename` in other entries' `dependsOn` arrays.
/// Preserves the surviving entries' `sectionID` / `generatedByCheck` /
/// `hint`, plus the manifest's pattern families, notebook checks,
/// `sections` list, and assignment-scope global variables/expressions —
/// deleting one script must never drop sections or other suite metadata.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestRemovingScript(manifestJSON: String, filename: String) -> String? {
    guard let props = decodeManifest(fromJSON: manifestJSON)

    else {
        return nil
    }
    let updated = props.testSuites
        .filter { $0.script != filename }
        .enumerated()
        .map { idx, e in ConfiguredSuiteEntry(e, order: idx + 1, dependsOn: e.dependsOn.filter { $0 != filename }) }
    return try? makeWorkerManifestJSON(preserving: props, testSuites: updated, language: props.language)
}

// `manifestWithRederivedLanguage` used to live here: on every starter-notebook
// write it re-derived the language from the new notebook's kernel and rewrote
// the manifest when the answer differed.
//
// It treated the recorded language as "a memo of what was last resolved rather
// than a fixed declaration" — its own words — which is the assumption this arc
// removed. A declaration does not go stale when content changes. An author
// converting a Python assignment to R changes the language in the dropdown that
// exists for exactly that purpose, and uploading a notebook no longer rewrites
// it underneath them.

/// Rebuilds the manifest for `props` with a new suite list, carrying every
/// other field forward.
///
/// This is the overload a suite edit should call. The stored manifest is
/// copied and only what the caller passes is replaced, so a field this
/// rebuild does not know about is preserved without being named. The old
/// builder wrote a fresh dictionary from a list of fields, and
/// `languageDeclared`, `minimumRunnerVersion`, `activity` and
/// `graderOnlyFiles` were each dropped by a rebuild that forgot one.
/// `language` is explicit because a rebuild may be the act of changing it.
func makeWorkerManifestJSON(
    preserving props: TestProperties,
    testSuites: [ConfiguredSuiteEntry],
    patternFamilies: [PatternFamily]? = nil,
    notebookChecks: [NotebookCheck]? = nil,
    sections: [TestSuiteSection]? = nil,
    globalVariables: [FamilyVariable]? = nil,
    globalExpressions: [PersonalizationExpression]? = nil,
    language: AssignmentLanguage?
) throws -> String {
    var next = props
    try next.replaceSuite(
        testSuites,
        patternFamilies: patternFamilies ?? props.patternFamilies,
        notebookChecks: notebookChecks ?? props.notebookChecks)
    next.sections = sections ?? props.sections
    next.globalVariables = globalVariables ?? props.globalVariables
    next.globalExpressions = globalExpressions ?? props.globalExpressions
    next.language = language
    return try encodeManifest(next)
}

/// Builds a manifest from nothing: the assignment create paths, and the
/// tests. A rebuild of a stored manifest goes through the `preserving:`
/// overload above, which keeps every field it is not asked to replace.
func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool,
    gradingMode: String = "worker",
    submissionMode: String = "notebook",
    githubSubmission: Bool = false,
    githubStatusChecks: Bool = false,
    requiredFiles: [String] = [],
    timeLimitSeconds: Int = 10,
    starterNotebook: String? = "assignment.ipynb",
    patternFamilies: [PatternFamily] = [],
    notebookChecks: [NotebookCheck] = [],
    sections: [TestSuiteSection] = [],
    globalVariables: [FamilyVariable] = [],
    globalExpressions: [PersonalizationExpression] = [],
    achievements: [Achievement] = [],
    disabledBuiltInAwardIDs: [String] = [],
    builtInAchievementsSeeded: Bool = false,
    datasets: [DatasetSpec] = [],
    language: AssignmentLanguage? = nil,
    languageDeclared: Bool = false,
    minimumRunnerVersion: String? = nil,
    activity: ClassActivity? = nil
) throws -> String {
    guard let grading = GradingMode(rawValue: gradingMode) else {
        throw WebAssignmentError.invalidParameter(
            name: "gradingMode", reason: "Unknown grading mode \"\(gradingMode)\".")
    }
    guard let submission = SubmissionMode(rawValue: submissionMode) else {
        throw WebAssignmentError.invalidParameter(
            name: "submissionMode", reason: "Unknown submission mode \"\(submissionMode)\".")
    }
    var props = TestProperties(
        gradingMode: grading,
        submissionMode: submission,
        githubSubmission: githubSubmission,
        githubStatusChecks: githubStatusChecks,
        requiredFiles: requiredFiles,
        timeLimitSeconds: timeLimitSeconds,
        makefile: includeMakefile ? MakefileConfig(target: nil) : nil,
        starterNotebook: starterNotebook,
        language: language,
        // Recorded only when true: the flag says the question was answered,
        // so its absence is the one "not answered" state.
        languageDeclared: languageDeclared ? true : nil,
        minimumRunnerVersion: (minimumRunnerVersion?.isEmpty == false) ? minimumRunnerVersion : nil,
        activity: activity,
        sections: sections,
        globalVariables: globalVariables,
        globalExpressions: globalExpressions,
        datasets: datasets,
        achievements: achievements,
        disabledBuiltInAwardIDs: disabledBuiltInAwardIDs,
        builtInAchievementsSeeded: builtInAchievementsSeeded)
    try props.replaceSuite(testSuites, patternFamilies: patternFamilies, notebookChecks: notebookChecks)
    return try encodeManifest(props)
}

extension TestProperties {
    /// Replaces the suite with `entries` in dependency order and rebuilds the
    /// unified `testItems` list in authored order.
    fileprivate mutating func replaceSuite(
        _ entries: [ConfiguredSuiteEntry],
        patternFamilies: [PatternFamily],
        notebookChecks: [NotebookCheck]
    ) throws {
        // Topologically sorted so the runner can process dependencies with a
        // single linear pass (parents always appear before children).
        testSuites = try topologicallySorted(entries).map(TestSuiteEntry.init(configured:))
        testItems = orderedTestItems(
            testSuites: entries, patternFamilies: patternFamilies, notebookChecks: notebookChecks)
    }
}

extension TestSuiteEntry {
    /// A manifest entry from an editor row. The tier string is normalized
    /// upstream (`normalizeTier`) or read off a `TestTier`, so a value that is
    /// not a tier is a programming error: refused here rather than stored
    /// where every later decode of the manifest would fail.
    fileprivate init(configured entry: ConfiguredSuiteEntry) throws {
        guard let tier = TestTier(rawValue: entry.tier) else {
            throw WebAssignmentError.invalidParameter(
                name: "tier", reason: "\"\(entry.tier)\" is not a test tier.")
        }
        self.init(
            tier: tier,
            script: entry.script,
            name: entry.displayName,
            dependsOn: entry.dependsOn,
            points: entry.points,
            generatedBy: entry.generatedBy,
            generatedByCheck: entry.generatedByCheck,
            sectionID: entry.sectionID,
            hint: entry.hint,
            timeLimitSeconds: entry.timeLimitSeconds,
            failureDetail: entry.failureDetail)
    }
}

/// Builds the unified `[TestItem]` list in authored order for the manifest.
/// `testSuites` is expected pre-topological-sort (i.e. authored order); each
/// family / check is emitted once, at its first generated entry, with any
/// unreferenced specs appended so nothing is dropped.
private func orderedTestItems(
    testSuites: [ConfiguredSuiteEntry],
    patternFamilies: [PatternFamily],
    notebookChecks: [NotebookCheck]
) -> [TestItem] {
    let familyByID = Dictionary(patternFamilies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let checkByID = Dictionary(notebookChecks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var items: [TestItem] = []
    var seen = Set<String>()
    for entry in testSuites {
        if let fid = entry.generatedBy, let fam = familyByID[fid], seen.insert(fid).inserted {
            items.append(.family(fam))
        } else if let cid = entry.generatedByCheck, let chk = checkByID[cid], seen.insert(cid).inserted {
            items.append(.check(chk))
        }
    }
    for fam in patternFamilies where seen.insert(fam.id).inserted {
        items.append(.family(fam))
    }
    for chk in notebookChecks where seen.insert(chk.id).inserted {
        items.append(.check(chk))
    }
    return items
}

/// Returns `entries` in topological order (prerequisites before dependents)
/// while honouring authored position as tightly as the dependency graph
/// allows.
///
/// Uses Kahn's algorithm but with an **authored-position priority queue**
/// instead of FIFO.  At each step we emit the ready node (inDegree == 0)
/// with the smallest original index.  This preserves the instructor's
/// suite-editor order whenever the dependency graph doesn't force a
/// different ordering — e.g. a family that depends on `publictest_a.py`
/// and is authored right after it stays right after it, rather than
/// being demoted to the tail by a FIFO queue that processes trailing
/// no-dep scripts before satisfied dependents re-enter.
///
/// Regression guard: `testApply_familyWithDependencyStaysInlineAfterPrereq`
/// (v0.4.95).
private func topologicallySorted(_ entries: [ConfiguredSuiteEntry]) -> [ConfiguredSuiteEntry] {
    var inDegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    var byScript: [String: ConfiguredSuiteEntry] = [:]
    var origIdx: [String: Int] = [:]

    for (i, entry) in entries.enumerated() {
        byScript[entry.script] = entry
        origIdx[entry.script] = i
        inDegree[entry.script, default: 0] += 0
        for dep in entry.dependsOn {
            dependents[dep, default: []].append(entry.script)
            inDegree[entry.script, default: 0] += 1
        }
    }

    var ready: Set<String> = Set(
        entries.filter { inDegree[$0.script, default: 0] == 0 }.map(\.script)
    )
    var result: [ConfiguredSuiteEntry] = []
    result.reserveCapacity(entries.count)
    while !ready.isEmpty {
        // Pop the ready node with the smallest authored index — that's
        // what keeps a family in-line with its prereq rather than
        // letting downstream no-dep scripts jump ahead of it.
        guard
            let nodeName = ready.min(by: {
                (origIdx[$0] ?? 0) < (origIdx[$1] ?? 0)
            }), let entry = byScript[nodeName]
        else { break }
        ready.remove(nodeName)
        result.append(entry)
        for dependent in dependents[nodeName] ?? [] {
            inDegree[dependent, default: 1] -= 1
            if inDegree[dependent, default: 0] == 0 {
                ready.insert(dependent)
            }
        }
    }
    // Fall back to original order if a cycle somehow slipped through
    // upstream validation.
    return result.count == entries.count ? result : entries
}

/// SHA-256 hex digest of `setup.manifest`.  Used by the auto-retest
/// trigger as the dedup key for "manifest unchanged since last retest".
func manifestHash(_ manifestJSON: String) -> String {
    sha256HexDigest(manifestJSON)
}

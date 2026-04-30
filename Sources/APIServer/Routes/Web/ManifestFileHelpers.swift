// APIServer/Routes/Web/ManifestFileHelpers.swift
//
// Read, mutate, and serialize `TestProperties` manifest JSON: dependent
// lookups, generated-by checks, add/remove script entries, the worker-
// facing manifest builder, topological sort, and the hash used as the
// auto-retest dedup key.  Extracted from AssignmentHelpers.swift
// (issue #442) — no behaviour changes.

import Vapor
import Core
import Foundation

/// Returns the scripts in the manifest that list `filename` in their `dependsOn`.
func manifestDependents(manifestJSON: String, filename: String) -> [String] {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
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
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
        return nil
    }
    return props.testSuites.first(where: { $0.script == filename })?.generatedBy
}

/// Returns true when the setup's manifest has at least one test entry
/// (raw script or generated-by-family).  Used by `saveEditedAssignment`
/// to refuse saving an empty suite.
func setupHasAnyTestEntries(manifestJSON: String) throws -> Bool {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
    else { return false }
    return !props.testSuites.isEmpty
}

/// Returns updated manifest JSON with a new `TestSuiteEntry` appended.
/// Preserves all existing entries, grading mode, makefile config,
/// starterNotebook, and pattern families.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestAddingScript(
    manifestJSON: String,
    entry: ConfiguredSuiteEntry
) -> String? {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
        return nil
    }
    let existing = props.testSuites.enumerated().map { idx, e in
        ConfiguredSuiteEntry(
            script: e.script,
            tier: e.tier.rawValue,
            order: idx + 1,
            dependsOn: e.dependsOn,
            points: e.points,
            displayName: e.name,
            generatedBy: e.generatedBy
        )
    }
    let nextOrder = (existing.map(\.order).max() ?? 0) + 1
    let newEntry = ConfiguredSuiteEntry(
        script: entry.script,
        tier: entry.tier,
        order: nextOrder,
        dependsOn: entry.dependsOn,
        points: entry.points,
        displayName: entry.displayName,
        generatedBy: entry.generatedBy
    )
    let updated = existing + [newEntry]
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: props.patternFamilies
    )
}

/// Returns updated manifest JSON with the entry for `filename` removed.
/// Also clears references to `filename` in other entries' `dependsOn` arrays.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestRemovingScript(manifestJSON: String, filename: String) -> String? {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
        return nil
    }
    let updated = props.testSuites
        .filter { $0.script != filename }
        .enumerated()
        .map { idx, e in
            ConfiguredSuiteEntry(
                script: e.script,
                tier: e.tier.rawValue,
                order: idx + 1,
                dependsOn: e.dependsOn.filter { $0 != filename },
                points: e.points,
                displayName: e.name,
                generatedBy: e.generatedBy
            )
        }
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: props.patternFamilies
    )
}

func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool,
    gradingMode: String = "worker",
    starterNotebook: String? = "assignment.ipynb",
    patternFamilies: [PatternFamily] = [],
    notebookChecks: [NotebookCheck] = [],
    sections: [TestSuiteSection] = []
) throws -> String {
    // Topologically sort so the runner can process dependencies with a single
    // linear pass (parents always appear before children in the array).
    let sorted = topologicallySorted(testSuites)

    let testSuiteJSON: [[String: Any]] = sorted.map { entry in
        var dict: [String: Any] = ["tier": entry.tier, "script": entry.script]
        if let n = entry.displayName, !n.isEmpty {
            dict["name"] = n
        }
        if !entry.dependsOn.isEmpty {
            dict["dependsOn"] = entry.dependsOn
        }
        if entry.points > 1 {
            dict["points"] = entry.points
        }
        if let fid = entry.generatedBy, !fid.isEmpty {
            dict["generatedBy"] = fid
        }
        if let cid = entry.generatedByCheck, !cid.isEmpty {
            dict["generatedByCheck"] = cid
        }
        if let sid = entry.sectionID, !sid.isEmpty {
            dict["sectionID"] = sid
        }
        return dict
    }
    var manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": gradingMode,
        "requiredFiles": [],
        "testSuites": testSuiteJSON,
        "timeLimitSeconds": 10,
        "makefile": includeMakefile ? ["target": NSNull()] : NSNull()
    ]
    if let starterNotebook {
        manifest["starterNotebook"] = starterNotebook
    }
    if !patternFamilies.isEmpty {
        // Encode the typed family values via JSONEncoder (keys sorted for
        // reproducibility), then reparse with JSONSerialization so they
        // splice into the dictionary-of-Any shape used here.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let familyData = try encoder.encode(patternFamilies)
        if let parsed = try JSONSerialization.jsonObject(with: familyData) as? [Any] {
            manifest["patternFamilies"] = parsed
        }
    }
    if !notebookChecks.isEmpty {
        // Same encode-then-reparse trick as patternFamilies above.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checksData = try encoder.encode(notebookChecks)
        if let parsed = try JSONSerialization.jsonObject(with: checksData) as? [Any] {
            manifest["notebookChecks"] = parsed
        }
    }
    if !sections.isEmpty {
        // Route sections through JSONEncoder (same pattern patternFamilies
        // uses above) so all fields — including `variables` (v0.4.100+)
        // — round-trip through the manifest.  Pre-v0.4.102 we hand-
        // rolled a minimal `[id, name]` dict that silently dropped the
        // section's variables on every save, which meant any family
        // CRUD or suite PUT wiped shared inputs the instructor had
        // just declared.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sectionData = try encoder.encode(sections)
        if let parsed = try JSONSerialization.jsonObject(with: sectionData) as? [Any] {
            manifest["sections"] = parsed
        }
    }
    let data = try JSONSerialization.data(withJSONObject: manifest)
    return String(data: data, encoding: .utf8) ?? "{}"
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
    var inDegree:   [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    var byScript:   [String: ConfiguredSuiteEntry] = [:]
    var origIdx:    [String: Int] = [:]

    for (i, entry) in entries.enumerated() {
        byScript[entry.script] = entry
        origIdx[entry.script]  = i
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
        guard let nodeName = ready.min(by: {
            (origIdx[$0] ?? 0) < (origIdx[$1] ?? 0)
        }), let entry = byScript[nodeName] else { break }
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

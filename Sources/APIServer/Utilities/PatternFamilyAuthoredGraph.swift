// APIServer/Utilities/PatternFamilyAuthoredGraph.swift
//
// The authored-suite graph phases of applyPatternFamilies (split out of
// PatternFamilyApplication.swift in the 0.5 cleanup; the #1123 extraction
// created these functions, this split gives them their own file):
// cycle detection over the authored dependency graph, reconstruction of the
// authored ordering for pre-authoredItems callers, section-contiguity
// validation, and family-ref dependency validation.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Authored-graph cycle detection

/// Detects dependency cycles on the authored graph where raw scripts are
/// identified by filename and families are identified by `family:<id>`.
/// `family:<id>` edges point to the family node (not to its generated
/// scripts) so the graph stays small.  Uses Kahn's algorithm.
func detectAuthoredCycles(
    authoredRaw: [AuthoredRawScript],
    families: [PatternFamily]
) throws {
    var prereqs: [String: [String]] = [:]  // node → prerequisites of that node

    for r in authoredRaw {
        let node = r.script
        prereqs[node, default: []].append(contentsOf: r.dependsOn.map(normaliseNode))
    }
    for f in families {
        let node = familyDepToken(f.id)
        prereqs[node, default: []].append(contentsOf: f.dependsOn.map(normaliseNode))
    }

    // Include every referenced prerequisite as a node so Kahn's terminates.
    for (_, deps) in prereqs {
        for d in deps where prereqs[d] == nil {
            prereqs[d] = []
        }
    }

    var inDegree: [String: Int] = prereqs.mapValues { $0.count }
    var dependents: [String: [String]] = [:]
    for (node, deps) in prereqs {
        for d in deps {
            dependents[d, default: []].append(node)
        }
    }

    var queue = inDegree.filter { $0.value == 0 }.map(\.key)
    var processed = 0
    while !queue.isEmpty {
        let node = queue.removeLast()
        processed += 1
        for dependent in dependents[node, default: []] {
            inDegree[dependent, default: 0] -= 1
            if inDegree[dependent] == 0 {
                queue.append(dependent)
            }
        }
    }

    guard processed == inDegree.count else {
        throw Abort(
            .unprocessableEntity,
            reason: "Dependency graph contains a cycle among scripts and/or pattern families."
        )
    }
}

/// Normalises a dependency token to its canonical node form.  Raw
/// filenames stay as-is; `family:<id>` tokens keep the prefix so they
/// don't collide with a real file name like "family" (filename has no
/// colon; a clash is impossible in practice).
func normaliseNode(_ dep: String) -> String { dep }

// MARK: - Extracted phases (#1123)

/// Reconstructs the authored ordering from an existing manifest, for the
/// legacy (`authoredItems == nil`) path: walk `testSuites` in order, emit a
/// script item for each raw entry, one family item at the position of each
/// family's first generated entry, and one check item at the position of
/// each check's (single) generated entry.  Families/checks present in
/// `nextFamilies` / `resolvedChecks` but absent from the old manifest
/// (i.e. newly added) are appended at the end.  This preserves the
/// instructor's hand-placed position across a family- or check-modal save.
func reconstructAuthoredOrdering(
    props: TestProperties,
    nextFamilies: [PatternFamily],
    resolvedChecks: [NotebookCheck],
    normaliseSectionID: (String?) -> String?
) -> [AuthoredSuiteItem] {
    let nextFamilyIDs = Set(nextFamilies.map(\.id))
    let nextCheckIDs = Set(resolvedChecks.map(\.id))
    var rebuilt: [AuthoredSuiteItem] = []
    var seenFamilyIDs: Set<String> = []
    var seenCheckIDs: Set<String> = []
    for entry in props.testSuites {
        if let fid = entry.generatedBy {
            guard !seenFamilyIDs.contains(fid) else { continue }
            seenFamilyIDs.insert(fid)
            if nextFamilyIDs.contains(fid) {
                rebuilt.append(
                    .family(
                        id: fid,
                        sectionID: normaliseSectionID(entry.sectionID)
                    ))
            }
        } else if let cid = entry.generatedByCheck {
            guard !seenCheckIDs.contains(cid) else { continue }
            seenCheckIDs.insert(cid)
            if nextCheckIDs.contains(cid) {
                rebuilt.append(
                    .check(
                        id: cid,
                        sectionID: normaliseSectionID(entry.sectionID)
                    ))
            }
        } else {
            rebuilt.append(
                .script(
                    AuthoredRawScript(
                        script: entry.script,
                        tier: entry.tier,
                        points: entry.points,
                        displayName: entry.name,
                        dependsOn: entry.dependsOn,
                        sectionID: normaliseSectionID(entry.sectionID),
                        hint: entry.hint,
                        timeLimitSeconds: entry.timeLimitSeconds
                    )))
        }
    }
    for f in nextFamilies where !seenFamilyIDs.contains(f.id) {
        rebuilt.append(.family(id: f.id, sectionID: nil))
    }
    for c in resolvedChecks where !seenCheckIDs.contains(c.id) {
        rebuilt.append(.check(id: c.id, sectionID: nil))
    }
    return rebuilt
}

/// Enforces that items with the same `sectionID` form a contiguous block
/// (nil / ungrouped counts too).  Clients are expected to group `items[]`
/// before sending; enforcing it server-side catches UI bugs early instead of
/// producing confusing manifests where the same section straddles another
/// section.  Internal (not private) so it has direct unit tests.
func validateAuthoredSectionContiguity(_ items: [AuthoredSuiteItem]) throws {
    var seenCompleted: Set<String?> = []
    var current: String?
    var haveStarted = false
    for item in items {
        let sid: String? = {
            switch item {
            case .script(let s): return s.sectionID
            case .family(_, let sid): return sid
            case .check(_, let sid): return sid
            }
        }()
        if !haveStarted {
            current = sid
            haveStarted = true
            continue
        }
        if sid != current {
            seenCompleted.insert(current)
            if seenCompleted.contains(sid) {
                let label = sid ?? "<ungrouped>"
                throw Abort(
                    .unprocessableEntity,
                    reason: "Items with sectionID '\(label)' are not contiguous; "
                        + "group all items of a section together before saving.")
            }
            current = sid
        }
    }
}

/// Validates every `family:<id>` dependency token: raw scripts and notebook
/// checks may only reference families in `families`; a family may reference
/// other families but never itself.  (Plain script-filename deps are
/// validated by `validateManifestDependencies` after expansion, so they
/// reference an existing entry in the post-expansion `testSuites`.)
func validateFamilyRefDependencies(
    authoredRawEntries: [AuthoredRawScript],
    families: [PatternFamily],
    checks: [NotebookCheck]
) throws {
    let knownFamilyIDs = Set(families.map(\.id))
    for r in authoredRawEntries {
        for dep in r.dependsOn {
            if let fid = parseFamilyDepToken(dep), !knownFamilyIDs.contains(fid) {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Script '\(r.script)' depends on unknown pattern family '\(fid)'.")
            }
        }
    }
    for f in families {
        for dep in f.dependsOn {
            if let fid = parseFamilyDepToken(dep) {
                if fid == f.id {
                    throw Abort(
                        .unprocessableEntity,
                        reason: "Pattern family '\(f.id)' cannot depend on itself.")
                }
                guard knownFamilyIDs.contains(fid) else {
                    throw Abort(
                        .unprocessableEntity,
                        reason: "Pattern family '\(f.id)' depends on unknown family '\(fid)'.")
                }
            }
        }
    }
    for c in checks {
        for dep in c.dependsOn {
            if let fid = parseFamilyDepToken(dep), !knownFamilyIDs.contains(fid) {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(c.id)' depends on unknown pattern family '\(fid)'.")
            }
        }
    }
}

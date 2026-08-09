// APIServer/Utilities/PatternFamilyApplication+SuiteEntries.swift
//
// Phase 5 of `applyPatternFamilies`: turn the authored ordering plus the
// already-rendered artifacts into the manifest's `testSuites` list.
//
// Split out of PatternFamilyApplication.swift (#1253).  This phase is a pure
// function of its inputs — it reads no database, mutates no zip, and every
// value it needs is decided by the time it runs — which is what made it the
// first piece to lift out of a 575-line body.

import Core
import Foundation

/// Accumulates the manifest's ordered `testSuites` list.
///
/// The order counter and the emitted-id sets are state shared by the authored
/// pass and the two defensive passes, so they live on a type rather than as
/// variables captured by nested closures.  That is also what keeps each
/// emit step short enough to read on its own.
private struct SuiteEntryBuilder {
    let familyByID: [String: PatternFamily]
    let checkByID: [String: NotebookCheck]
    /// familyID → the generated filenames of its enabled cases, used to expand
    /// `family:<id>` dependency tokens.
    let familyFilenames: [String: [String]]
    let artifacts: RenderedFamilyArtifacts
    let renderedCheckByID: [String: GeneratedScript]
    /// The zip phase's deletion set.  A dependency pointing at a file that is
    /// going away is dropped rather than persisted as a dangling reference.
    let deletedFilenames: Set<String>

    var entries: [ConfiguredSuiteEntry] = []
    private var order = 0
    private var emittedFamilyIDs: Set<String> = []
    private var emittedCheckIDs: Set<String> = []

    init(
        familyByID: [String: PatternFamily],
        checkByID: [String: NotebookCheck],
        familyFilenames: [String: [String]],
        artifacts: RenderedFamilyArtifacts,
        renderedCheckByID: [String: GeneratedScript],
        deletedFilenames: Set<String>
    ) {
        self.familyByID = familyByID
        self.checkByID = checkByID
        self.familyFilenames = familyFilenames
        self.artifacts = artifacts
        self.renderedCheckByID = renderedCheckByID
        self.deletedFilenames = deletedFilenames
    }

    /// Expands `family:<id>` tokens to concrete generated filenames and drops
    /// anything the zip phase is deleting.  Deduplicates while preserving
    /// authored order.
    func expandDeps(_ deps: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for d in deps {
            if let fid = parseFamilyDepToken(d) {
                for f in familyFilenames[fid] ?? [] {
                    guard !deletedFilenames.contains(f), seen.insert(f).inserted else { continue }
                    out.append(f)
                }
            } else {
                guard !deletedFilenames.contains(d), seen.insert(d).inserted else { continue }
                out.append(d)
            }
        }
        return out
    }

    mutating func appendRawScript(_ s: AuthoredRawScript) {
        order += 1
        entries.append(
            ConfiguredSuiteEntry(
                script: s.script,
                tier: s.tier.rawValue,
                order: order,
                dependsOn: expandDeps(s.dependsOn),
                points: s.points,
                displayName: s.displayName,
                generatedBy: nil,
                sectionID: s.sectionID,
                hint: s.hint,
                timeLimitSeconds: s.timeLimitSeconds
            ))
    }

    /// Emits a family's existence guard, if it has one, and returns its
    /// filename so the cases can chain off it.
    private mutating func appendGuard(
        _ family: PatternFamily, inherited: [String], section: String?
    ) -> String? {
        guard let guardScript = artifacts.guardScripts[family.id] else { return nil }
        order += 1
        // The guard inherits the family's own prerequisites; the cases
        // chain off the guard, so prereqs → guard → cases.
        entries.append(
            ConfiguredSuiteEntry(
                script: guardScript.filename,
                tier: guardScript.tier.rawValue,
                order: order,
                dependsOn: inherited,
                points: guardScript.points,
                displayName: guardScript.displayName,
                generatedBy: guardScript.familyID,
                sectionID: section,
                // The guard inherits the family-level time limit.
                timeLimitSeconds: guardScript.timeLimitSeconds
            ))
        return guardScript.filename
    }

    /// Emits a family's generated entries: the existence guard first (for
    /// function-calling kinds), then one entry per enabled case wired to
    /// `dependsOn` the guard — so a missing function fails once on the guard
    /// and the cases auto-skip through the runner's dependency gate.  Shared
    /// by the authored-order pass and the defensive pass so the two can't
    /// drift on the guard wiring.  Consumes the render-once `artifacts`, so
    /// the manifest entries describe exactly the bytes the zip phase wrote.
    mutating func appendFamily(_ family: PatternFamily, section: String?) {
        guard emittedFamilyIDs.insert(family.id).inserted else { return }
        let inherited = expandDeps(family.dependsOn)
        let guardFilename = appendGuard(family, inherited: inherited, section: section)

        for generated in artifacts.caseScripts[family.id] ?? [] {
            order += 1
            // Generated-case deps are fully derived from the *current* spec:
            // the guard first (so a missing function reports the guard as the
            // unmet prerequisite), then the family's inherited prerequisites
            // (deduped).  We deliberately do NOT carry the prior manifest
            // entry's deps forward.  Doing so made a once-set family-level
            // dependency permanently "sticky": every regeneration re-read the
            // old generated row's deps, so clearing `family.dependsOn` (or
            // dropping a hand-written prereq the family used to point at) could
            // never remove it from the generated rows — leaving a dangling
            // reference that no edit could delete, because a hand-written
            // script is not a generated file and so never entered the
            // `expandDeps` `deletedFilenames` filter.
            var combined: [String] = []
            var seen = Set<String>()
            for d in (guardFilename.map { [$0] } ?? []) + inherited {
                guard seen.insert(d).inserted else { continue }
                combined.append(d)
            }
            // Per-test time limit is resolved by the renderer
            // (`case.resolvedTimeLimit(defaults:)`, then normalised so a
            // 0/negative becomes nil) and carried on `generated`.
            entries.append(
                ConfiguredSuiteEntry(
                    script: generated.filename,
                    tier: generated.tier.rawValue,
                    order: order,
                    dependsOn: combined,
                    points: generated.points,
                    displayName: generated.displayName,
                    generatedBy: generated.familyID,
                    sectionID: section,
                    timeLimitSeconds: generated.timeLimitSeconds
                ))
        }
    }

    /// Emits one notebook check's generated entry.  Shared by the authored
    /// pass and the defensive pass for the same can't-drift reason.
    mutating func appendCheck(_ check: NotebookCheck, section: String?) {
        guard let generated = renderedCheckByID[check.id],
            emittedCheckIDs.insert(check.id).inserted
        else { return }
        order += 1
        // Per-test time limit comes from the check spec (0/negative → nil,
        // i.e. inherit the assignment-wide default).
        entries.append(
            ConfiguredSuiteEntry(
                script: generated.filename,
                tier: generated.tier.rawValue,
                order: order,
                dependsOn: expandDeps(check.dependsOn),
                points: generated.points,
                displayName: generated.displayName,
                generatedBy: nil,
                generatedByCheck: check.id,
                sectionID: section,
                timeLimitSeconds: normalizedGeneratedTimeLimit(check.timeLimitSeconds)
            ))
    }

    mutating func appendAuthored(_ item: AuthoredSuiteItem) {
        switch item {
        case .script(let s):
            appendRawScript(s)
        case .family(let fid, let section):
            guard let family = familyByID[fid] else { return }
            appendFamily(family, section: section)
        case .check(let cid, let section):
            guard let check = checkByID[cid] else { return }
            appendCheck(check, section: section)
        }
    }

    func hasEmitted(familyID: String) -> Bool { emittedFamilyIDs.contains(familyID) }
    func hasEmitted(checkID: String) -> Bool { emittedCheckIDs.contains(checkID) }
}

/// Builds the manifest's ordered `testSuites` list.
///
/// Raw scripts keep their authored position, tier, points, hint and
/// dependencies; each family expands in place to its existence guard followed
/// by one entry per enabled case; each notebook check expands to its single
/// generated entry.  `family:<id>` dependency tokens are expanded to concrete
/// generated filenames here, so the persisted manifest — the one the runner
/// consumes — never contains a token.
func buildConfiguredSuiteEntries(
    itemsForOrdering: [AuthoredSuiteItem],
    families: [PatternFamily],
    checks: [NotebookCheck],
    artifacts: RenderedFamilyArtifacts,
    renderedCheckByID: [String: GeneratedScript],
    deletedFilenames: Set<String>
) -> [ConfiguredSuiteEntry] {
    var familyFilenames: [String: [String]] = [:]
    for f in families {
        familyFilenames[f.id] = f.cases
            .filter(\.enabled)
            .map { c in
                generatedScriptFilename(
                    familyID: f.id,
                    caseKey: c.key,
                    tier: c.resolvedTier(defaults: f.defaults)
                )
            }
    }

    var builder = SuiteEntryBuilder(
        familyByID: Dictionary(uniqueKeysWithValues: families.map { ($0.id, $0) }),
        checkByID: Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) }),
        familyFilenames: familyFilenames,
        artifacts: artifacts,
        renderedCheckByID: renderedCheckByID,
        deletedFilenames: deletedFilenames
    )

    for item in itemsForOrdering {
        builder.appendAuthored(item)
    }

    // Defensive: anything in `families` / `checks` that wasn't referenced by
    // `itemsForOrdering` still needs its generated entries emitted (e.g. if
    // the caller forgot to include a newly added family).
    for family in families where !builder.hasEmitted(familyID: family.id) {
        builder.appendFamily(family, section: nil)
    }
    for check in checks where !builder.hasEmitted(checkID: check.id) {
        builder.appendCheck(check, section: nil)
    }

    return builder.entries
}

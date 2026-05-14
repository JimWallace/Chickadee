// APIServer/Utilities/PatternFamilyApplication.swift
//
// Applies a list of PatternFamily specs — and optionally an authored,
// ordered suite (interleaving raw scripts and families) — to an APITestSetup.
// Owns the atomic save path:
//
//   1. Validates the spec (families + family-ref dependencies).
//   2. Diffs old vs new generated `.py` files and mutates the zip.
//   3. Rebuilds `testSuites` in authored order, expanding every
//      `family:<id>` token in `dependsOn` to the concrete generated
//      filenames so the runner never needs to understand families.
//   4. Rewrites the manifest JSON and persists it.
//
// The runner's cache key includes manifest bytes, so updating the manifest
// here is what causes runners to fetch a fresh copy after an edit — there is
// no separate bust-the-cache step.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Authored suite model

/// The instructor-authored metadata for a raw (hand-written) script row —
/// the tier/points/deps that would otherwise have lived in a `suiteConfig`
/// JSON blob before the v0.4.79 unification.  `dependsOn` may include
/// `family:<id>` tokens; they're expanded before the manifest is persisted.
struct AuthoredRawScript: Equatable {
    let script: String
    let tier: TestTier
    let points: Int
    let displayName: String?
    let dependsOn: [String]
    let sectionID: String?

    init(
        script: String, tier: TestTier, points: Int,
        displayName: String?, dependsOn: [String], sectionID: String? = nil
    ) {
        self.script = script
        self.tier = tier
        self.points = points
        self.displayName = displayName
        self.dependsOn = dependsOn
        self.sectionID = sectionID
    }
}

/// One position in the unified suite-edit list.  Either a raw script entry,
/// a reference to one of the families in `nextFamilies`, or a reference to
/// one of the checks in `nextChecks`.  Array ordering is authoritative for
/// UI order — a family's generated scripts occupy a contiguous block at the
/// family's position; a check produces exactly one entry at the check's
/// position.  The optional `sectionID` carried on each item is a pure
/// display-grouping concern: the server stamps it onto the resulting
/// `TestSuiteEntry` so the student submission page can group results, but
/// it doesn't influence the dependency graph or run order beyond the
/// existing `testSuites[]` ordering.
enum AuthoredSuiteItem: Equatable {
    case script(AuthoredRawScript)
    case family(id: String, sectionID: String?)
    case check(id: String, sectionID: String?)

    /// Convenience for the pre-sections call sites that don't care about
    /// sections.  Swift can't give enum associated values a default value,
    /// but a same-name static function that forwards lets `.family(id:)`
    /// keep resolving at old call sites without an audit.
    static func family(id: String) -> AuthoredSuiteItem {
        .family(id: id, sectionID: nil)
    }
}

// MARK: - Family-ref helpers

/// `family:<id>` is the author-facing syntax for "depends on every enabled
/// case of family <id>".  Nothing in the persisted manifest should ever
/// carry this token — `applyPatternFamilies` expands it before save.
private let familyRefPrefix = "family:"

/// Returns the family id if `dep` is a `family:<id>` token, otherwise nil.
func parseFamilyDepToken(_ dep: String) -> String? {
    guard dep.hasPrefix(familyRefPrefix) else { return nil }
    let id = String(dep.dropFirst(familyRefPrefix.count))
    return id.isEmpty ? nil : id
}

/// Builds the authored-form token for a family reference.
func familyDepToken(_ familyID: String) -> String {
    "\(familyRefPrefix)\(familyID)"
}

// MARK: - Outcome

struct PatternFamilyApplyResult: Equatable {
    let writtenFiles: [String]
    let deletedFiles: [String]
    let manifestBefore: String
    let manifestAfter: String
}

// MARK: - Entry point

/// Validates `nextFamilies` + any `authoredItems` the caller provides,
/// applies zip mutations, expands `family:<id>` dependency tokens, and
/// rewrites the manifest in authored order.  On success, persists the
/// updated manifest to the database.
///
/// - When `authoredItems == nil` the function preserves the raw-script
///   entries from the existing manifest verbatim (their tier/points/deps
///   survive) and appends generated entries after them — the original
///   v0.4.76 behaviour, used by callers that aren't driving the unified
///   suite editor (e.g. the v0.4.77 save-edit re-apply and pre-v0.4.79
///   tests).
/// - When `authoredItems != nil` the caller is the source of truth for
///   position, tier, points, displayName, and dependencies of every raw
///   row; generated rows are interleaved at each family's authored
///   position.  Families referenced by `authoredItems` must appear in
///   `nextFamilies`; families in `nextFamilies` not referenced by
///   `authoredItems` are appended at the end (defensive).
@discardableResult
func applyPatternFamilies(
    to setup: APITestSetup,
    nextFamilies: [PatternFamily],
    nextChecks: [NotebookCheck]? = nil,
    authoredItems: [AuthoredSuiteItem]? = nil,
    sections: [TestSuiteSection]? = nil,
    globalVariables: [FamilyVariable]? = nil,
    globalExpressions: [PersonalizationExpression]? = nil,
    on db: Database
) async throws -> PatternFamilyApplyResult {

    let oldManifest = setup.manifest
    guard let data = oldManifest.data(using: .utf8),
        let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
    else {
        throw Abort(.internalServerError, reason: "Test setup manifest is not valid JSON")
    }

    // Resolve the final checks list: caller wins; otherwise carry forward
    // whatever's on the manifest already.  Mirrors the section resolution
    // below so this function is the single save path for both concepts.
    let resolvedChecks: [NotebookCheck] = nextChecks ?? props.notebookChecks

    // ── 1. Resolve section list (caller wins; otherwise carry old manifest).
    let resolvedSections: [TestSuiteSection] = sections ?? props.sections

    // Resolve assignment-scope variables (Slice 1): caller wins; otherwise
    // carry forward whatever was on the manifest already.
    let resolvedGlobalVariables: [FamilyVariable] = globalVariables ?? props.globalVariables

    // Resolve assignment-scope expressions (Slice 2): same carry-forward
    // semantics.  Expressions don't reach the runner or get inlined into
    // raw scripts — they only participate in notebook substitution
    // at student first-open — so they bypass the renderer below and
    // flow straight into the manifest write.
    let resolvedGlobalExpressions: [PersonalizationExpression] =
        globalExpressions ?? props.globalExpressions
    var seenSectionIDs: Set<String> = []
    for s in resolvedSections {
        guard seenSectionIDs.insert(s.id).inserted else {
            throw Abort(
                .unprocessableEntity,
                reason: "Duplicate section id '\(s.id)'.")
        }
    }
    let knownSectionIDs = seenSectionIDs

    /// Silently rewrites stale `sectionID` references (pointing at a
    /// section that's not in `resolvedSections`) to `nil`.  Defends
    /// against the client-race where the editor deletes a section
    /// locally but an in-flight PUT still references it.
    func normaliseSectionID(_ sid: String?) -> String? {
        guard let sid else { return nil }
        return knownSectionIDs.contains(sid) ? sid : nil
    }

    // ── 2. Figure out the authored raw-entry list + ordering ────────────
    let authoredRawEntries: [AuthoredRawScript]
    let itemsForOrdering: [AuthoredSuiteItem]
    if let authoredItems {
        authoredRawEntries = authoredItems.compactMap { item in
            if case .script(let s) = item {
                return AuthoredRawScript(
                    script: s.script,
                    tier: s.tier,
                    points: s.points,
                    displayName: s.displayName,
                    dependsOn: s.dependsOn,
                    sectionID: normaliseSectionID(s.sectionID)
                )
            }
            return nil
        }
        itemsForOrdering = authoredItems.map { item in
            switch item {
            case .script(let s):
                return .script(
                    AuthoredRawScript(
                        script: s.script,
                        tier: s.tier,
                        points: s.points,
                        displayName: s.displayName,
                        dependsOn: s.dependsOn,
                        sectionID: normaliseSectionID(s.sectionID)
                    ))
            case .family(let id, let sid):
                return .family(id: id, sectionID: normaliseSectionID(sid))
            case .check(let id, let sid):
                return .check(id: id, sectionID: normaliseSectionID(sid))
            }
        }
    } else {
        authoredRawEntries = props.testSuites
            .filter { !$0.isGenerated }
            .map { e in
                AuthoredRawScript(
                    script: e.script,
                    tier: e.tier,
                    points: e.points,
                    displayName: e.name,
                    dependsOn: e.dependsOn,
                    sectionID: normaliseSectionID(e.sectionID)
                )
            }
        // Reconstruct authored ordering from the existing manifest: walk
        // testSuites in order, emit a script item for each raw entry,
        // one family item at the position of each family's first generated
        // entry, and one check item at the position of each check's
        // (single) generated entry.  Families/checks present in
        // `nextFamilies` / `resolvedChecks` but absent from the old
        // manifest (i.e. newly added) are appended at the end.  This
        // preserves the instructor's hand-placed position across a family-
        // or check-modal save, which goes through the legacy
        // (authoredItems == nil) path.
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
                            sectionID: normaliseSectionID(entry.sectionID)
                        )))
            }
        }
        for f in nextFamilies where !seenFamilyIDs.contains(f.id) {
            rebuilt.append(.family(id: f.id, sectionID: nil))
        }
        for c in resolvedChecks where !seenCheckIDs.contains(c.id) {
            rebuilt.append(.check(id: c.id, sectionID: nil))
        }
        itemsForOrdering = rebuilt
    }

    // ── 2a. Enforce that items with the same sectionID form a contiguous
    // block (nil / ungrouped counts too).  Clients are expected to group
    // items[] before sending; enforcing it server-side catches UI bugs
    // early instead of producing confusing manifests where the same
    // section straddles another section.
    do {
        var seenCompleted: Set<String?> = []
        var current: String? = nil
        var haveStarted = false
        for item in itemsForOrdering {
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

    // ── 2. Validate: family spec + family-ref dependency tokens ─────────
    let authoredAsTestSuites = authoredRawEntries.map {
        TestSuiteEntry(
            tier: $0.tier, script: $0.script, name: $0.displayName,
            dependsOn: $0.dependsOn, points: $0.points, generatedBy: nil
        )
    }
    // v0.4.100: build familySectionID map so validator knows which
    // family lives in which section for section-variable ref checking.
    var familySectionIDForValidation: [String: String] = [:]
    for item in itemsForOrdering {
        if case .family(let fid, let sid) = item, let sid {
            familySectionIDForValidation[fid] = sid
        }
    }
    try validatePatternFamilies(
        nextFamilies,
        testSuites: authoredAsTestSuites,
        sections: resolvedSections,
        familySectionID: familySectionIDForValidation
    )
    try validateNotebookChecks(
        resolvedChecks,
        patternFamilies: nextFamilies,
        testSuites: authoredAsTestSuites
    )

    let knownFamilyIDs = Set(nextFamilies.map(\.id))
    for r in authoredRawEntries {
        for dep in r.dependsOn {
            if let fid = parseFamilyDepToken(dep), !knownFamilyIDs.contains(fid) {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Script '\(r.script)' depends on unknown pattern family '\(fid)'.")
            }
        }
    }
    for f in nextFamilies {
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

    // Same family-dep reference check for notebook checks.  Plain
    // script-filename deps are validated by validateManifestDependencies
    // after expansion (so they reference an existing entry in the
    // post-expansion testSuites).
    for c in resolvedChecks {
        for dep in c.dependsOn {
            if let fid = parseFamilyDepToken(dep), !knownFamilyIDs.contains(fid) {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(c.id)' depends on unknown pattern family '\(fid)'.")
            }
        }
    }

    // Cycle detection on the authored graph (family ids + script filenames
    // as a single node set; family:<id> edges expand to the family node,
    // NOT to its generated scripts, so family→family cycles are caught).
    try detectAuthoredCycles(
        authoredRaw: authoredRawEntries,
        families: nextFamilies
    )

    // ── 3. Diff generated filenames and mutate the zip ──────────────────
    // Old-side filenames for both generators are pooled into one set so
    // the deletion diff is computed in one shot.  Notebook checks may
    // produce sidecar files (e.g. `_expected_<id>.csv` for
    // `.dataFrameEquality`); both the script and the sidecars are
    // tracked here so removing a check cleans up all of its files.
    let oldGeneratedFilenames = Set(
        props.patternFamilies.flatMap(patternFamilyAllGeneratedFilenames)
    ).union(
        props.notebookChecks.flatMap(notebookCheckAllGeneratedFilenames)
    )

    // Build a familyID → sectionID map from the authored items, so we can
    // look up each family's home section and prepend its variables.  If
    // the authored ordering doesn't reference a family (defensive path
    // below), that family renders with no section variables — which
    // matches its "unanchored" status.
    var familySectionID: [String: String] = [:]
    for item in itemsForOrdering {
        if case .family(let fid, let sid) = item, let sid {
            familySectionID[fid] = sid
        }
    }
    let sectionVarsByID: [String: [FamilyVariable]] = Dictionary(
        uniqueKeysWithValues: resolvedSections.map { ($0.id, $0.variables) }
    )
    func sectionVars(forFamily fid: String) -> [FamilyVariable] {
        guard let sid = familySectionID[fid] else { return [] }
        return sectionVarsByID[sid] ?? []
    }

    var renderedByFilename: [String: GeneratedScript] = [:]
    for family in nextFamilies {
        for generated in renderPatternFamily(
            family, sectionVariables: sectionVars(forFamily: family.id), globalVariables: resolvedGlobalVariables)
        {
            renderedByFilename[generated.filename] = generated
        }
    }
    // Render notebook checks alongside pattern families so a single zip
    // mutation pass writes everything.  Each check produces one `.py`
    // file plus zero or more sidecar files (e.g. `_expected_<id>.csv`
    // for `.dataFrameEquality`).  Sidecars don't have a `GeneratedScript`
    // — they aren't entries in the suite — but they DO need to be in
    // `newGeneratedFilenames` so stale ones get diffed away when a check
    // changes kind or is removed.
    var renderedCheckByID: [String: GeneratedScript] = [:]
    var sidecarFilesToWrite: [String: String] = [:]
    for check in resolvedChecks {
        let bundle = renderNotebookCheck(check)
        renderedByFilename[bundle.script.filename] = bundle.script
        renderedCheckByID[check.id] = bundle.script
        for (name, content) in bundle.sidecars {
            sidecarFilesToWrite[name] = content
        }
    }
    let newGeneratedFilenames = Set(renderedByFilename.keys)
        .union(sidecarFilesToWrite.keys)

    let toDelete = oldGeneratedFilenames.subtracting(newGeneratedFilenames)
    // Merge generated `.py` sources with check sidecars (e.g. expected
    // CSVs) into the single write map.  applyScriptChangesToZip is
    // bytes-agnostic — it doesn't care that some entries are Python and
    // others are CSV.
    var toWrite = renderedByFilename.mapValues(\.source)
    for (name, content) in sidecarFilesToWrite {
        toWrite[name] = content
    }

    // Slice 1: re-inline global + section variables into every raw
    // (non-generated) Python test script.  Idempotent — the prepender
    // strips any existing Chickadee inputs block before adding the new
    // one, so unchanged scripts stay byte-identical and unchanged
    // toWrite entries skip the zip rewrite.  Raw scripts are
    // identified from `itemsForOrdering` (.script case) so we use the
    // new authored sectionID, not whatever the old manifest had.
    for item in itemsForOrdering {
        guard case .script(let s) = item else { continue }
        let filename = s.script
        guard filename.lowercased().hasSuffix(".py") else { continue }
        // If this filename was just generated (e.g. instructor renamed a
        // raw script to clash with a family-generated name), the family
        // version wins — skip the raw-script overlay.
        guard renderedByFilename[filename] == nil else { continue }
        guard
            let existing = readScriptFromZip(
                zipPath: setup.zipPath,
                filename: filename)
        else { continue }
        let sectionVars: [FamilyVariable] = {
            guard let sid = s.sectionID else { return [] }
            return sectionVarsByID[sid] ?? []
        }()
        let updated = TestScriptVariablePrepender.prependToRawScript(
            existing,
            variables: resolvedGlobalVariables + sectionVars
        )
        if updated != existing {
            toWrite[filename] = updated
        }
    }

    try applyScriptChangesToZip(
        zipPath: setup.zipPath,
        writes: toWrite,
        deletions: Array(toDelete)
    )

    // ── 4. Build new `testSuites` in authored order, expanding family refs ─
    let familyByID: [String: PatternFamily] = Dictionary(
        uniqueKeysWithValues: nextFamilies.map { ($0.id, $0) }
    )
    var familyFilenames: [String: [String]] = [:]
    for f in nextFamilies {
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

    func expandDeps(_ deps: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for d in deps {
            if let fid = parseFamilyDepToken(d) {
                for f in familyFilenames[fid] ?? [] {
                    guard !toDelete.contains(f), seen.insert(f).inserted else { continue }
                    out.append(f)
                }
            } else {
                guard !toDelete.contains(d), seen.insert(d).inserted else { continue }
                out.append(d)
            }
        }
        return out
    }

    let oldEntryByScript: [String: TestSuiteEntry] = Dictionary(
        uniqueKeysWithValues: props.testSuites.map { ($0.script, $0) }
    )

    let checkByID: [String: NotebookCheck] = Dictionary(
        uniqueKeysWithValues: resolvedChecks.map { ($0.id, $0) }
    )

    var newConfigured: [ConfiguredSuiteEntry] = []
    var order = 0
    var emittedFamilyIDs: Set<String> = []
    var emittedCheckIDs: Set<String> = []

    for item in itemsForOrdering {
        switch item {
        case .script(let s):
            order += 1
            newConfigured.append(
                ConfiguredSuiteEntry(
                    script: s.script,
                    tier: s.tier.rawValue,
                    order: order,
                    dependsOn: expandDeps(s.dependsOn),
                    points: s.points,
                    displayName: s.displayName,
                    generatedBy: nil,
                    sectionID: s.sectionID
                ))

        case .family(let fid, let familySection):
            guard let family = familyByID[fid], !emittedFamilyIDs.contains(fid) else { continue }
            emittedFamilyIDs.insert(fid)
            let inherited = expandDeps(family.dependsOn)
            for generated in renderPatternFamily(
                family, sectionVariables: sectionVars(forFamily: fid), globalVariables: resolvedGlobalVariables)
            {
                order += 1
                let prior = oldEntryByScript[generated.filename]
                let perCase = expandDeps(prior?.dependsOn ?? [])
                var combined: [String] = []
                var seen = Set<String>()
                for d in inherited + perCase {
                    guard seen.insert(d).inserted else { continue }
                    combined.append(d)
                }
                newConfigured.append(
                    ConfiguredSuiteEntry(
                        script: generated.filename,
                        tier: generated.tier.rawValue,
                        order: order,
                        dependsOn: combined,
                        points: generated.points,
                        displayName: generated.displayName,
                        generatedBy: generated.familyID,
                        sectionID: familySection
                    ))
            }

        case .check(let cid, let checkSection):
            guard let check = checkByID[cid],
                let generated = renderedCheckByID[cid],
                !emittedCheckIDs.contains(cid)
            else { continue }
            emittedCheckIDs.insert(cid)
            order += 1
            let inherited = expandDeps(check.dependsOn)
            newConfigured.append(
                ConfiguredSuiteEntry(
                    script: generated.filename,
                    tier: generated.tier.rawValue,
                    order: order,
                    dependsOn: inherited,
                    points: generated.points,
                    displayName: generated.displayName,
                    generatedBy: nil,
                    generatedByCheck: check.id,
                    sectionID: checkSection
                ))
        }
    }

    // Defensive: any family in `nextFamilies` that wasn't referenced by
    // `authoredItems` still needs its generated scripts emitted (e.g. if
    // the caller forgot to include a newly added family).
    for family in nextFamilies where !emittedFamilyIDs.contains(family.id) {
        let inherited = expandDeps(family.dependsOn)
        for generated in renderPatternFamily(
            family, sectionVariables: sectionVars(forFamily: family.id), globalVariables: resolvedGlobalVariables)
        {
            order += 1
            let prior = oldEntryByScript[generated.filename]
            let perCase = expandDeps(prior?.dependsOn ?? [])
            var combined: [String] = []
            var seen = Set<String>()
            for d in inherited + perCase {
                guard seen.insert(d).inserted else { continue }
                combined.append(d)
            }
            newConfigured.append(
                ConfiguredSuiteEntry(
                    script: generated.filename,
                    tier: generated.tier.rawValue,
                    order: order,
                    dependsOn: combined,
                    points: generated.points,
                    displayName: generated.displayName,
                    generatedBy: generated.familyID,
                    sectionID: nil
                ))
        }
    }

    // Same defensive pass for checks: any check not referenced by
    // `authoredItems` still needs its generated entry emitted.
    for check in resolvedChecks where !emittedCheckIDs.contains(check.id) {
        guard let generated = renderedCheckByID[check.id] else { continue }
        order += 1
        let inherited = expandDeps(check.dependsOn)
        newConfigured.append(
            ConfiguredSuiteEntry(
                script: generated.filename,
                tier: generated.tier.rawValue,
                order: order,
                dependsOn: inherited,
                points: generated.points,
                displayName: generated.displayName,
                generatedBy: nil,
                generatedByCheck: check.id,
                sectionID: nil
            ))
    }

    let newManifest = try makeWorkerManifestJSON(
        testSuites: newConfigured,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: nextFamilies,
        notebookChecks: resolvedChecks,
        sections: resolvedSections,
        globalVariables: resolvedGlobalVariables,
        globalExpressions: resolvedGlobalExpressions
    )

    // Belt-and-suspenders: the post-expansion manifest is the one the runner
    // will actually consume.  It must not contain any `family:<id>` tokens,
    // must reference only existing scripts, and must still be acyclic.
    if let postData = newManifest.data(using: .utf8),
        let postProps = try? ManifestCodec.decoder.decode(TestProperties.self, from: postData)
    {
        try validateManifestDependencies(postProps)
    }

    setup.manifest = newManifest
    try await setup.save(on: db)

    return PatternFamilyApplyResult(
        writtenFiles: Array(toWrite.keys).sorted(),
        deletedFiles: Array(toDelete).sorted(),
        manifestBefore: oldManifest,
        manifestAfter: newManifest
    )
}

// MARK: - Authored-graph cycle detection

/// Detects dependency cycles on the authored graph where raw scripts are
/// identified by filename and families are identified by `family:<id>`.
/// `family:<id>` edges point to the family node (not to its generated
/// scripts) so the graph stays small.  Uses Kahn's algorithm.
private func detectAuthoredCycles(
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
private func normaliseNode(_ dep: String) -> String { dep }

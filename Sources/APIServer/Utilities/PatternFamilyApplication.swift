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
    /// Authoritative raw body to write into the zip for this script. When
    /// nil, the existing file content is preserved (variables are still
    /// re-inlined for `.py` scripts). When non-nil, this content replaces
    /// the file — the channel `PUT /suite` uses to create or update a
    /// hand-written script without a separate `POST /scripts`.
    let content: String?
    /// Optional instructor hint, persisted onto the generated
    /// `TestSuiteEntry.hint` so it surfaces as a "💡 Hint" callout on failure
    /// (PR2's display-time join). nil = no hint.
    let hint: String?
    /// Optional per-test execution time limit (seconds), persisted onto the
    /// generated `TestSuiteEntry.timeLimitSeconds`. nil = inherit the
    /// assignment-wide default. Only meaningful for hand-written raw scripts;
    /// generated family / notebook-check entries currently inherit the default.
    let timeLimitSeconds: Int?

    init(
        script: String, tier: TestTier, points: Int,
        displayName: String?, dependsOn: [String], sectionID: String? = nil,
        content: String? = nil, hint: String? = nil, timeLimitSeconds: Int? = nil
    ) {
        self.script = script
        self.tier = tier
        self.points = points
        self.displayName = displayName
        self.dependsOn = dependsOn
        self.sectionID = sectionID
        self.content = content
        self.hint = hint
        self.timeLimitSeconds = timeLimitSeconds
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
///
/// The body is a step-by-step orchestration — see the `── N. <phase>`
/// comment markers: resolve inputs (caller-wins with manifest fallback),
/// build the authored ordering, validate, render generated scripts ONCE
/// (`renderFamilyArtifacts` — the zip write and the manifest rebuild both
/// consume the same artifacts, so they can't desync), mutate the zip, then
/// rebuild and persist the manifest.  The self-contained phases live as
/// free functions below (`reconstructAuthoredOrdering`,
/// `validateAuthoredSectionContiguity`, `validateFamilyRefDependencies`,
/// `renderFamilyArtifacts`, `rawScriptOverlayWrites`); what remains
/// inline genuinely threads state between phases (#1123).
@discardableResult
func applyPatternFamilies(  // swiftlint:disable:this function_body_length
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
    guard let props = decodeManifest(fromJSON: oldManifest)

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

    // Per-student personalization input names (global + section `=`
    // expressions).  The renderer uses this set to tell a `$name` arg / an
    // `expectedVarRef` that resolves to a per-student value — loaded from
    // `_ck_inputs.py` at grading time — apart from one naming a literal
    // variable (prepended at save time).
    let perStudentExpressionNames: Set<String> = Set(
        resolvedGlobalExpressions.map(\.name)
            + resolvedSections.flatMap { $0.expressions.map(\.name) }
    )
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
    // (Section-contiguity is enforced right after — see
    // `validateAuthoredSectionContiguity` below.)
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
                    sectionID: normaliseSectionID(s.sectionID),
                    content: s.content,
                    hint: s.hint,
                    timeLimitSeconds: s.timeLimitSeconds
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
                        sectionID: normaliseSectionID(s.sectionID),
                        content: s.content,
                        hint: s.hint,
                        timeLimitSeconds: s.timeLimitSeconds
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
                    sectionID: normaliseSectionID(e.sectionID),
                    hint: e.hint,
                    timeLimitSeconds: e.timeLimitSeconds
                )
            }
        itemsForOrdering = reconstructAuthoredOrdering(
            props: props,
            nextFamilies: nextFamilies,
            resolvedChecks: resolvedChecks,
            normaliseSectionID: normaliseSectionID
        )
    }

    try validateAuthoredSectionContiguity(itemsForOrdering)

    // ── 3. Validate: family spec + family-ref dependency tokens ─────────
    let authoredAsTestSuites = authoredRawEntries.map {
        TestSuiteEntry(
            tier: $0.tier, script: $0.script, name: $0.displayName,
            dependsOn: $0.dependsOn, points: $0.points, generatedBy: nil
        )
    }
    // v0.4.100: the familyID → sectionID map tells the validator which
    // family lives in which section (section-variable ref checking) and
    // later tells the renderer whose section variables to prepend.  Built
    // ONCE here — the render phase used to rebuild it with an identical
    // loop (#1123).
    var familySectionID: [String: String] = [:]
    for item in itemsForOrdering {
        if case .family(let fid, let sid) = item, let sid {
            familySectionID[fid] = sid
        }
    }
    try validatePatternFamilies(
        nextFamilies,
        testSuites: authoredAsTestSuites,
        sections: resolvedSections,
        familySectionID: familySectionID,
        globalVariableNames: Set(resolvedGlobalVariables.map(\.name)),
        perStudentExpressionNames: perStudentExpressionNames
    )
    // The assignment's language decides how each case renders and which
    // extension it gets. Prefer the authored items when supplied — they carry
    // the edit being applied, which may be the very first `.R` test — and fall
    // back to the stored manifest (which records the language once known).
    let previousLanguage = AssignmentLanguage.resolve(for: setup, manifest: props)
    let resolvedLanguage: AssignmentLanguage? = {
        // The authored items carry the edit being applied, which may be the very
        // first non-Python graded script — the `.R` or `.lua` that establishes
        // the language before the manifest has recorded anything. Resolve it
        // from the extension so the families/checks render in the right language
        // at that moment. Any non-Python language wins, in `allCases` order
        // (R before Lua) for a deterministic answer on a mixed edit. Checking
        // only `.r` here is what made the first `.lua` script save as Python.
        //
        // Python is excluded by name so that adding a `.py` helper to an R
        // assignment cannot flip the render language; the stored manifest stays
        // authoritative in that case.
        var authoredLanguages: Set<AssignmentLanguage> = []
        for item in authoredItems ?? [] {
            guard case .script(let raw) = item,
                let language = AssignmentLanguage(
                    scriptExtension: URL(fileURLWithPath: raw.script).pathExtension),
                language != .python
            else { continue }
            authoredLanguages.insert(language)
        }
        return AssignmentLanguage.allCases.first { authoredLanguages.contains($0) }
            ?? previousLanguage
    }()
    // Authoring falls back to Python, deliberately and locally — this is NOT the
    // old resolution default leaking back in.
    //
    // Refusing here would be circular: a pattern family is frequently the FIRST
    // thing authored on an assignment, and generating its scripts is how the
    // suite acquires a graded script in the first place. "Add a graded script
    // before you can add a family" asks the instructor for the output as a
    // precondition of the input. So when nothing names a language yet, author in
    // Python — and note that the save RECORDS the choice into the manifest, so
    // the ambiguity exists for exactly one save and never silently again.
    //
    // What the Optional buys is upstream of this line: an `.R`/`.lua`/`.m`
    // assignment can no longer arrive here as Python by fallthrough, because
    // those signals now resolve positively and nil means only "nothing said".
    let assignmentLanguage = resolvedLanguage ?? .python

    try validateNotebookChecks(
        resolvedChecks,
        patternFamilies: nextFamilies,
        testSuites: authoredAsTestSuites,
        language: assignmentLanguage
    )

    try validateFamilyRefDependencies(
        authoredRawEntries: authoredRawEntries,
        families: nextFamilies,
        checks: resolvedChecks
    )

    // Cycle detection on the authored graph (family ids + script filenames
    // as a single node set; family:<id> edges expand to the family node,
    // NOT to its generated scripts, so family→family cycles are caught).
    try detectAuthoredCycles(
        authoredRaw: authoredRawEntries,
        families: nextFamilies
    )

    // ── 4. Render generated scripts ONCE, then diff and mutate the zip ──
    let mutations = try renderAndApplyZipMutations(
        plan: GeneratedArtifactPlan(
            families: nextFamilies,
            checks: resolvedChecks,
            familySectionID: familySectionID,
            sections: resolvedSections,
            globalVariables: resolvedGlobalVariables,
            perStudentNames: perStudentExpressionNames,
            itemsForOrdering: itemsForOrdering,
            language: assignmentLanguage,
            previousLanguage: previousLanguage
        ),
        previousProps: props,
        zipPath: setup.zipPath
    )

    // ── 5. Build new `testSuites` in authored order, expanding family refs ─
    let newConfigured = buildConfiguredSuiteEntries(
        itemsForOrdering: itemsForOrdering,
        families: nextFamilies,
        checks: resolvedChecks,
        artifacts: mutations.artifacts,
        renderedCheckByID: mutations.renderedCheckByID,
        deletedFilenames: mutations.deletedFilenames
    )

    // ── 6. Rewrite and persist the manifest ─────────────────────────────
    let newManifest = try makeWorkerManifestJSON(
        testSuites: newConfigured,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        // Preserve the submission mode and required-files list across the
        // family/suite rebuild, like `language` below — a fresh-dict rebuild
        // loses anything not threaded through.
        submissionMode: props.submissionMode.rawValue,
        requiredFiles: props.requiredFiles,
        timeLimitSeconds: props.timeLimitSeconds,
        starterNotebook: props.starterNotebook,
        patternFamilies: nextFamilies,
        notebookChecks: resolvedChecks,
        sections: resolvedSections,
        globalVariables: resolvedGlobalVariables,
        globalExpressions: resolvedGlobalExpressions,
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
        language: assignmentLanguage,
        // Preserve the minimum-runner-version gate across the family rebuild.
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

    setup.manifest = newManifest
    try await setup.save(on: db)

    return PatternFamilyApplyResult(
        writtenFiles: mutations.writtenFilenames,
        deletedFiles: mutations.deletedFilenames.sorted(),
        manifestBefore: oldManifest,
        manifestAfter: newManifest
    )
}

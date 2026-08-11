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
    guard let props = decodeManifest(fromJSON: oldManifest) else {
        throw Abort(.internalServerError, reason: "Test setup manifest is not valid JSON")
    }

    // ── 1. Resolve caller arguments against the stored manifest ─────────
    let inputs = try ResolvedApplyInputs(
        props: props,
        nextChecks: nextChecks,
        sections: sections,
        globalVariables: globalVariables,
        globalExpressions: globalExpressions
    )

    // ── 2. Figure out the authored raw-entry list + ordering ────────────
    let ordering = buildAuthoredOrdering(
        authoredItems: authoredItems,
        props: props,
        families: nextFamilies,
        inputs: inputs
    )
    try validateAuthoredSectionContiguity(ordering.items)

    // ── 3. Resolve the language, then validate the whole save ───────────
    let language = resolveAuthoringLanguage(
        setup: setup, props: props, authoredItems: authoredItems)

    // A generated script has to be written in SOME syntax, so a save that
    // generates one needs a declared language. A save that generates nothing
    // does not — and refusing it would make a plain `.sh` suite uneditable,
    // which is a supported assignment shape, not an oversight.
    //
    // This is the authoring half of the rule the fallback census settled on:
    // fail loudly while authoring, never while grading. An instructor can fix a
    // missing declaration from the dropdown in seconds and this message says
    // so; a student cannot fix it at all.
    let generatesScripts =
        nextFamilies.contains { $0.cases.contains(where: \.enabled) } || !inputs.checks.isEmpty
    if language.language == nil, generatesScripts {
        throw Abort(.badRequest, reason: undeclaredLanguageGenerationMessage)
    }
    // Inert on the declared-None path: the guard above means nothing is
    // rendered there, and the manifest below records `language.language`, not
    // this — so the standin cannot leak into the declaration.
    let renderLanguage = language.language ?? .python

    try validatePatternFamilySave(
        families: nextFamilies,
        ordering: ordering,
        inputs: inputs,
        language: renderLanguage
    )

    // ── 4. Render generated scripts ONCE, then diff and mutate the zip ──
    let mutations = try renderAndApplyZipMutations(
        plan: GeneratedArtifactPlan(
            families: nextFamilies,
            checks: inputs.checks,
            familySectionID: ordering.familySectionID,
            sections: inputs.sections,
            globalVariables: inputs.globalVariables,
            perStudentNames: inputs.perStudentExpressionNames,
            itemsForOrdering: ordering.items,
            language: renderLanguage,
            previousLanguage: language.previous
        ),
        previousProps: props,
        zipPath: setup.zipPath
    )

    // ── 5. Build new `testSuites` in authored order, expanding family refs ─
    let newConfigured = buildConfiguredSuiteEntries(
        itemsForOrdering: ordering.items,
        families: nextFamilies,
        checks: inputs.checks,
        artifacts: mutations.artifacts,
        renderedCheckByID: mutations.renderedCheckByID,
        deletedFilenames: mutations.deletedFilenames
    )

    // ── 6. Rewrite and persist the manifest ─────────────────────────────
    let newManifest = try rebuildPatternFamilyManifest(
        entries: newConfigured,
        previousProps: props,
        families: nextFamilies,
        inputs: inputs,
        language: language.language
    )

    setup.manifest = newManifest
    try await setup.save(on: db)

    return PatternFamilyApplyResult(
        writtenFiles: mutations.writtenFilenames,
        deletedFiles: mutations.deletedFilenames.sorted(),
        manifestBefore: oldManifest,
        manifestAfter: newManifest
    )
}

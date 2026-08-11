// APIServer/Utilities/PatternFamilyApplication+Inputs.swift
//
// Phases 1-3 of `applyPatternFamilies`: resolve what the caller supplied
// against what the stored manifest already held, reconstruct the authored
// ordering, decide the assignment's language, and run every save-time
// validation.
//
// Split out of PatternFamilyApplication.swift (#1253).  These phases share
// state, which is why they were the ones left inline when the render and
// entry-building phases moved out — `ResolvedApplyInputs` is that shared state
// made explicit rather than threaded through a long argument list.

import Core
import Foundation
import Vapor

/// The caller's arguments resolved against the stored manifest.
///
/// Every field follows the same rule: the caller wins when it supplies a value,
/// otherwise the manifest's existing value carries forward. That rule is why
/// this is one save path for families, checks, sections, variables and
/// expressions alike — a partial save must not silently drop the concepts it
/// didn't mention.
struct ResolvedApplyInputs {
    let checks: [NotebookCheck]
    let sections: [TestSuiteSection]
    let globalVariables: [FamilyVariable]
    let globalExpressions: [PersonalizationExpression]

    /// Per-student personalization input names (global + section `=`
    /// expressions).  The renderer uses this set to tell a `$name` arg / an
    /// `expectedVarRef` that resolves to a per-student value — loaded from
    /// `_ck_inputs.py` at grading time — apart from one naming a literal
    /// variable (prepended at save time).
    let perStudentExpressionNames: Set<String>

    private let knownSectionIDs: Set<String>

    init(
        props: TestProperties,
        nextChecks: [NotebookCheck]?,
        sections: [TestSuiteSection]?,
        globalVariables: [FamilyVariable]?,
        globalExpressions: [PersonalizationExpression]?
    ) throws {
        self.checks = nextChecks ?? props.notebookChecks
        self.sections = sections ?? props.sections
        self.globalVariables = globalVariables ?? props.globalVariables
        // Expressions don't reach the runner or get inlined into raw scripts —
        // they only participate in notebook substitution at student first-open
        // — so they bypass the renderer and flow straight into the manifest.
        self.globalExpressions = globalExpressions ?? props.globalExpressions

        self.perStudentExpressionNames = Set(
            self.globalExpressions.map(\.name)
                + self.sections.flatMap { $0.expressions.map(\.name) }
        )

        var seen: Set<String> = []
        for s in self.sections {
            guard seen.insert(s.id).inserted else {
                throw Abort(.unprocessableEntity, reason: "Duplicate section id '\(s.id)'.")
            }
        }
        self.knownSectionIDs = seen
    }

    /// Silently rewrites stale `sectionID` references (pointing at a section
    /// that's not in `sections`) to `nil`.  Defends against the client-race
    /// where the editor deletes a section locally but an in-flight PUT still
    /// references it.
    func normaliseSectionID(_ sid: String?) -> String? {
        guard let sid else { return nil }
        return knownSectionIDs.contains(sid) ? sid : nil
    }
}

/// The authored suite as this save sees it: the raw (non-generated) scripts,
/// and the full ordered item list that positions families and checks among
/// them.
struct AuthoredOrdering {
    let rawEntries: [AuthoredRawScript]
    let items: [AuthoredSuiteItem]

    /// familyID → sectionID.  Built once and shared by the validator (which
    /// uses it for section-variable ref checking) and the renderer (which uses
    /// it to decide whose section variables to prepend), so the two cannot
    /// disagree about where a family lives (#1123).
    var familySectionID: [String: String] {
        var out: [String: String] = [:]
        for item in items {
            if case .family(let fid, let sid) = item, let sid {
                out[fid] = sid
            }
        }
        return out
    }

    /// The raw entries in the shape the validators expect.
    var rawAsTestSuites: [TestSuiteEntry] {
        rawEntries.map {
            TestSuiteEntry(
                tier: $0.tier, script: $0.script, name: $0.displayName,
                dependsOn: $0.dependsOn, points: $0.points, generatedBy: nil
            )
        }
    }
}

/// Builds the authored ordering.
///
/// When `authoredItems` is supplied the caller is the source of truth for
/// position, tier, points, displayName and dependencies of every raw row.
/// When it is nil the raw entries are preserved verbatim from the existing
/// manifest and generated entries are appended after them — the original
/// v0.4.76 behaviour, used by callers that aren't driving the unified suite
/// editor.
func buildAuthoredOrdering(
    authoredItems: [AuthoredSuiteItem]?,
    props: TestProperties,
    families: [PatternFamily],
    inputs: ResolvedApplyInputs
) -> AuthoredOrdering {
    guard let authoredItems else {
        let rawEntries = props.testSuites
            .filter { !$0.isGenerated }
            .map { e in
                AuthoredRawScript(
                    script: e.script,
                    tier: e.tier,
                    points: e.points,
                    displayName: e.name,
                    dependsOn: e.dependsOn,
                    sectionID: inputs.normaliseSectionID(e.sectionID),
                    hint: e.hint,
                    timeLimitSeconds: e.timeLimitSeconds
                )
            }
        return AuthoredOrdering(
            rawEntries: rawEntries,
            items: reconstructAuthoredOrdering(
                props: props,
                nextFamilies: families,
                resolvedChecks: inputs.checks,
                normaliseSectionID: inputs.normaliseSectionID
            )
        )
    }

    /// One rewrite of a raw script, shared by both lists below so the raw
    /// entries and the ordering can't disagree about a normalised sectionID.
    func normalised(_ s: AuthoredRawScript) -> AuthoredRawScript {
        AuthoredRawScript(
            script: s.script,
            tier: s.tier,
            points: s.points,
            displayName: s.displayName,
            dependsOn: s.dependsOn,
            sectionID: inputs.normaliseSectionID(s.sectionID),
            content: s.content,
            hint: s.hint,
            timeLimitSeconds: s.timeLimitSeconds
        )
    }

    let items: [AuthoredSuiteItem] = authoredItems.map { item in
        switch item {
        case .script(let s):
            return .script(normalised(s))
        case .family(let id, let sid):
            return .family(id: id, sectionID: inputs.normaliseSectionID(sid))
        case .check(let id, let sid):
            return .check(id: id, sectionID: inputs.normaliseSectionID(sid))
        }
    }
    let rawEntries: [AuthoredRawScript] = items.compactMap {
        if case .script(let s) = $0 { return s }
        return nil
    }
    return AuthoredOrdering(rawEntries: rawEntries, items: items)
}

/// The language this save renders in, and the one the previous manifest was
/// written in (which the deletion diff needs so old-extension scripts aren't
/// stranded when an assignment changes language).
struct AuthoringLanguageResolution {
    /// nil means the assignment declares no language — the author picked
    /// "None", which is a real answer and the right one for a suite of plain
    /// `.sh` scripts. It is NOT "nobody has been asked": every door that
    /// creates an assignment declares, so by the time a save reaches here the
    /// question has an answer.
    let language: AssignmentLanguage?
    let previous: AssignmentLanguage?
}

/// Decides which language the generated scripts render in.
///
/// The authored items carry the edit being applied, which may be the very
/// first non-Python graded script — the `.R` or `.lua` that establishes the
/// language before the manifest has recorded anything. Any non-Python language
/// wins, in `allCases` order for a deterministic answer on a mixed edit.
/// Checking only `.r` here is what made the first `.lua` script save as Python.
/// Python is excluded by name so adding a `.py` helper to an R assignment
/// cannot flip the render language; the stored manifest stays authoritative.
func resolveAuthoringLanguage(
    setup: APITestSetup,
    props: TestProperties,
    authoredItems: [AuthoredSuiteItem]?
) -> AuthoringLanguageResolution {
    let previous = AssignmentLanguage.resolve(for: setup, manifest: props)

    var authoredLanguages: Set<AssignmentLanguage> = []
    for item in authoredItems ?? [] {
        guard case .script(let raw) = item,
            let language = AssignmentLanguage(
                scriptExtension: URL(fileURLWithPath: raw.script).pathExtension),
            language != .python
        else { continue }
        authoredLanguages.insert(language)
    }
    let resolved = AssignmentLanguage.allCases.first { authoredLanguages.contains($0) } ?? previous

    // NO PYTHON FALLBACK. This used to end `?? .python`, justified as follows:
    //
    //     Refusing here would be circular: a pattern family is frequently the
    //     FIRST thing authored on an assignment, and generating its scripts is
    //     how the suite acquires a graded script in the first place.
    //
    // That was true while the language was INFERRED from content, when nil
    // honestly meant "nothing has named a language yet". Declaration dissolves
    // it: every door that creates an assignment declares, so nil here means the
    // author picked "None" and the circularity is gone — there is nothing to
    // wait for, only an answer to respect.
    //
    // The fallback was also actively wrong, not merely redundant. Every suite
    // save runs through this function, including saves that touch only raw
    // scripts and ordering, and the manifest rebuild ALWAYS records the value
    // it is handed — so reordering two `.sh` scripts on a declared-None
    // assignment silently rewrote its declaration to Python. The caller now
    // refuses only when the save would actually GENERATE something (which needs
    // a syntax) and persists nil otherwise.
    return AuthoringLanguageResolution(language: resolved, previous: previous)
}

/// Every save-time validation, in the order the pre-split function ran them.
///
/// Ordering is load-bearing: the family spec is checked before the notebook
/// checks that may reference it, and cycle detection runs last on the fully
/// resolved authored graph.
func validatePatternFamilySave(
    families: [PatternFamily],
    ordering: AuthoredOrdering,
    inputs: ResolvedApplyInputs,
    language: AssignmentLanguage
) throws {
    let rawAsTestSuites = ordering.rawAsTestSuites

    try validatePatternFamilies(
        families,
        testSuites: rawAsTestSuites,
        sections: inputs.sections,
        familySectionID: ordering.familySectionID,
        globalVariableNames: Set(inputs.globalVariables.map(\.name)),
        perStudentExpressionNames: inputs.perStudentExpressionNames
    )

    try validateNotebookChecks(
        inputs.checks,
        patternFamilies: families,
        testSuites: rawAsTestSuites,
        language: language
    )

    try validateFamilyRefDependencies(
        authoredRawEntries: ordering.rawEntries,
        families: families,
        checks: inputs.checks
    )

    // Cycle detection on the authored graph (family ids + script filenames
    // as a single node set; family:<id> edges expand to the family node,
    // NOT to its generated scripts, so family→family cycles are caught).
    try detectAuthoredCycles(
        authoredRaw: ordering.rawEntries,
        families: families
    )
}

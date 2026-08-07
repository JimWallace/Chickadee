// APIServer/Utilities/NotebookCheckValidator.swift
//
// Validates a list of `NotebookCheck` records before they are applied
// to a test setup.  Mirrors `PatternFamilyValidator.swift` for the
// parallel concept.  Split out of `ManifestValidation.swift` in
// v0.4.182.

import Core
import Vapor

/// Validates a list of notebook checks before they are applied to a test
/// setup.  Mirrors `validatePatternFamilies` for the parallel concept.
///
/// Checks:
/// - `id` is unique across the assignment, is a valid filename fragment.
/// - `points` is non-negative.
/// - kind-specific required fields are present and well-formed
///   (e.g. `.dataFrameShape` requires a Python-identifier `variable` and
///   non-negative integer `expectedRows` / `expectedCols`).
/// - generated check filenames don't collide with hand-written scripts
///   or with pattern-family generated filenames.
///
/// The per-kind field validation is dispatched through
/// `notebookCheckKindHandler(for:)`; this function handles the
/// kind-agnostic checks (id, points) and the cross-check filename
/// collision pass.
func validateNotebookChecks(
    _ checks: [NotebookCheck],
    patternFamilies: [PatternFamily] = [],
    testSuites: [TestSuiteEntry] = [],
    language: AssignmentLanguage = .python
) throws {
    var seenCheckIDs: Set<String> = []
    for check in checks {
        try validateKindSupport(check, language: language)
        guard isValidIdentifierFragment(check.id) else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check id '\(check.id)' must contain only letters, digits, and underscore")
        }
        guard seenCheckIDs.insert(check.id).inserted else {
            throw Abort(
                .unprocessableEntity,
                reason: "Duplicate notebook check id '\(check.id)'")
        }
        guard check.points >= 0 else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)': points must be non-negative")
        }

        try notebookCheckKindHandler(for: check.kind).validate(check, language: language)
    }

    // Filename collisions: every generated filename a check produces
    // (its test script + any sidecars like `_expected_<id>.csv`) must
    // not match a hand-written script or a pattern-family-generated
    // filename.  A future pattern family might generate the same name
    // as a future check; this catches that at save time so the runner
    // never sees a duplicate.
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    // Every language's filenames, so a check can't collide with a family's
    // generated name whichever language the assignment renders in.
    let familyFilenames = Set(
        AssignmentLanguage.allCases.flatMap { language in
            patternFamilies.flatMap { patternFamilyAllGeneratedFilenames($0, language: language) }
        }
    )
    var seenCheckFilenames: Set<String> = []
    for check in checks {
        for filename in notebookCheckAllGeneratedFilenames(check) {
            if rawScripts.contains(filename) {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', but a hand-written file with that name already exists. Rename the file or change the check id."
                )
            }
            if familyFilenames.contains(filename) {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', which collides with a pattern family's generated filename. Change the check id."
                )
            }
            if !seenCheckFilenames.insert(filename).inserted {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' would generate '\(filename)', which collides with another check's generated file. Change the check id."
                )
            }
        }
    }
}

/// Reject a kind with no renderer in this assignment's language at save time.
/// Rendering Python for an R assignment would emit a `.py` script the R suite
/// can never run, and the failure would surface as a confusing grading error
/// rather than an authoring mistake. Exhaustive so a future language cannot
/// silently skip kind-support validation (docs/language-handling-review.md §4).
private func validateKindSupport(_ check: NotebookCheck, language: AssignmentLanguage) throws {
    switch language {
    case .python:
        break
    case .r:
        if !notebookCheckKindSupportsR(check.kind) {
            throw unsupportedKind(
                check, language: "R", supports: notebookCheckKindSupportsR,
                handWrittenExtension: ".R")
        }
    case .lua:
        if !notebookCheckKindSupportsLua(check.kind) {
            throw unsupportedKind(
                check, language: "Lua", supports: notebookCheckKindSupportsLua,
                handWrittenExtension: ".lua")
        }
        // Regex cell-matching is rejected here rather than approximated in
        // the renderer. Lua patterns are a different language from PCRE —
        // no alternation, no `{n,m}`, `%d` for `\d` — so a pattern authored
        // against the Python or R renderer would not error under Lua, it
        // would quietly match the wrong thing and award marks on that
        // basis. Telling the instructor at save time is the only point at
        // which this is fixable.
        if check.kind == .cellContains, check.regex == true {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Notebook check '\(check.id)' (cell_contains) uses regex matching, which is not "
                    + "available for Lua assignments: Lua patterns are not compatible with the "
                    + "regular expressions the Python and R renderers use. Turn regex off to match "
                    + "the text literally."
            )
        }
    case .octave:
        if !notebookCheckKindSupportsOctave(check.kind) {
            throw unsupportedKind(
                check, language: "Octave", supports: notebookCheckKindSupportsOctave,
                handWrittenExtension: ".m")
        }
    // No `regex: true` refusal here, deliberately: Octave's regexp is
    // PCRE, so a pattern authored against the Python or R renderer
    // transfers — verified against octave-cli before claiming it.
    }
}

private func unsupportedKind(
    _ check: NotebookCheck, language: String,
    supports: (NotebookCheckKind) -> Bool, handWrittenExtension: String
) -> Abort {
    let supported = NotebookCheckKind.allCases
        .filter(supports)
        .map(\.rawValue)
        .sorted()
        .joined(separator: ", ")
    return Abort(
        .unprocessableEntity,
        reason:
            "Notebook check '\(check.id)' (\(check.kind.rawValue)) is not supported for "
            + "\(language) assignments — supported kinds are: \(supported). "
            + "Express this check as a hand-written \(handWrittenExtension) test for now."
    )
}

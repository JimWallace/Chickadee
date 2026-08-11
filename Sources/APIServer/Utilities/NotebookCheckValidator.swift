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
    language: AssignmentLanguage
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
        // Every language's filenames, matching the family-collision check
        // above and for the same reason: this asked only for Python's, so on a
        // non-Python assignment it compared `.py` names against a suite that
        // contains none and could never collide.
        //
        // DEDUPLICATED PER CHECK, and that is load-bearing rather than tidy:
        // two languages may legitimately share a generated extension (C++ and
        // Java both emit `.sh` wrappers), so one check yields the same filename
        // twice and would collide with ITSELF on the `seenCheckFilenames`
        // insert below — refusing every notebook check on every assignment.
        // The set exists to catch two DIFFERENT checks claiming one name.
        var seenForThisCheck: Set<String> = []
        let checkFilenames = AssignmentLanguage.allCases
            .flatMap { notebookCheckAllGeneratedFilenames(check, language: $0) }
            .filter { seenForThisCheck.insert($0).inserted }
        for filename in checkFilenames {
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

/// Whether `language` can render `kind` — THE predicate, shared by the save-time
/// refusal below and by the authoring UI's menu.
///
/// It existed only inside `validateKindSupport`, so the "Add Test" menu had no
/// way to ask: it offered all ten kinds on every assignment, six of which a Lua
/// author could not save and ALL of which a C++ or Racket author could not.
/// Discovering that by being refused is the thing issue #1290 is about.
func notebookCheckKindIsSupported(_ kind: NotebookCheckKind, language: AssignmentLanguage) -> Bool {
    switch language {
    case .python: return true
    case .r: return notebookCheckKindSupportsR(kind)
    case .lua: return notebookCheckKindSupportsLua(kind)
    case .octave: return notebookCheckKindSupportsOctave(kind)
    case .cpp, .racket, .java:
        // Categorical, not per-kind: these are upload-only, so there is no
        // submitted notebook for any kind to inspect.
        return false
    }
}

/// Why `language` cannot render `kind`, or nil when it can. Phrased for a menu
/// tooltip — short, and it names the language.
func notebookCheckKindUnsupportedReason(
    _ kind: NotebookCheckKind, language: AssignmentLanguage
) -> String? {
    guard !notebookCheckKindIsSupported(kind, language: language) else { return nil }
    switch language {
    case .cpp, .racket, .java:
        return "\(language.displayName) assignments are upload-only, so there is no submitted "
            + "notebook to check."
    case .r, .lua, .octave, .python:
        return "Not available for \(language.displayName) assignments."
    }
}

/// Why `language` cannot use the form field `field` on `kind`, or nil when it
/// can.
///
/// The FIELD-level sibling of `notebookCheckKindUnsupportedReason`, and it
/// exists because a kind being available does not make all of its options
/// available. `cellContains` is supported on Lua; `cellContains` with
/// `regex: true` is not, and that refusal lived only at save time — the kind
/// map the Add Test menu reads is keyed by kind, so nothing could express it.
/// A Lua author ticked a box whose save was guaranteed to fail. That is the
/// same discoverability defect #1290 fixed one level up, one level down.
///
/// Returns nil for every other field, and is asked generically by the form
/// schema builder so a second field-level refusal has somewhere to go.
func notebookCheckFieldUnsupportedReason(
    _ field: String, kind: NotebookCheckKind, language: AssignmentLanguage
) -> String? {
    guard kind == .cellContains, field == "regex" else { return nil }
    switch language {
    case .python, .r, .octave, .cpp, .racket, .java:
        // R and Octave both take a pattern authored against the Python
        // renderer: Octave's regexp is PCRE (verified against octave-cli
        // before claiming it) and R's engine accepts the same constructs.
        // C++ and Racket never reach here — the kind itself is refused.
        return nil
    case .lua:
        return "Lua patterns are not compatible with the regular expressions the Python and R "
            + "renderers use — no alternation, no {n,m}, %d for \\d — so a pattern authored "
            + "against them would not error under Lua, it would quietly match the wrong thing. "
            + "Turn regex off to match the text literally."
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
        // Regex cell-matching is rejected rather than approximated in the
        // renderer: a pattern authored against the Python or R renderer would
        // not error under Lua, it would quietly match the wrong thing and
        // award marks on that basis.
        //
        // The REASON now comes from `notebookCheckFieldUnsupportedReason`, so
        // the authoring form can disable the checkbox with the same words this
        // refusal uses. Save time used to be the only point at which an
        // instructor learned this, which made it the only point at which it was
        // fixable — after they had written the pattern.
        if check.regex == true,
            let reason = notebookCheckFieldUnsupportedReason(
                "regex", kind: check.kind, language: .lua)
        {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Notebook check '\(check.id)' (\(check.kind.rawValue)) uses regex matching, "
                    + "which is not available for Lua assignments: \(reason)"
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
    case .cpp, .racket, .java:
        // Categorical, not per-kind, for all three: notebook checks inspect a
        // submitted notebook, and an upload-only language has no notebook
        // workflow — there is nothing for any kind to check. Pattern families
        // and hand-written tests are the whole authoring surface.
        //
        // The refusal is NOT a statement about any of these languages'
        // expressiveness: several kinds would render fine against a notebook if
        // one existed. If a kernel ever lands for one of them, this arm is what
        // to revisit.
        //
        // ONE ARM RATHER THAN THREE. C++ and Racket carried a hand-written
        // Abort each, and adding Java's would have been the third copy of one
        // sentence — the shape this codebase keeps paying for. The reason text
        // already comes from `notebookCheckKindUnsupportedReason`, the same
        // predicate the Add Test menu and `get_server_info` read, so folding
        // them makes the save-time refusal and the discoverable answer the same
        // string by construction. The rendered message is byte-identical to
        // what C++ and Racket produced before the fold.
        guard let reason = notebookCheckKindUnsupportedReason(check.kind, language: language)
        else { break }
        throw Abort(
            .unprocessableEntity,
            reason:
                "Notebook check '\(check.id)' (\(check.kind.rawValue)) is not available for "
                + "\(language.displayName) assignments: \(reason) Use a pattern family or a "
                + "hand-written \(handWrittenTestExtension(language)) test instead."
        )
    }
}

/// The file extension an instructor should reach for when writing a test by
/// hand in `language`.
///
/// Not simply `sourceFileExtension`, and C++ is why: a bare `.cpp` is not
/// something the runner executes (there is no C++ `ScriptInterpreter` case, by
/// design), so a C++ author's hand-written test is a `.sh` wrapper. Java's
/// `.java` *is* executable — single-file source mode — so it answers its own
/// extension even though its GENERATED cases are `.sh` wrappers like C++'s.
/// That difference is exactly why this cannot be derived from
/// `generatesLanguagelessWrapper`.
private func handWrittenTestExtension(_ language: AssignmentLanguage) -> String {
    switch language {
    case .cpp: return ".sh"
    case .racket, .java, .python, .r, .lua, .octave:
        return ".\(language.sourceFileExtension)"
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

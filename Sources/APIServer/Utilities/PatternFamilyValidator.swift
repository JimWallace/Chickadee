// APIServer/Utilities/PatternFamilyValidator.swift
//
// Validates a list of `PatternFamily` records before they are applied
// to a test setup.  Split out of `ManifestValidation.swift` in
// v0.4.182 along with `NotebookCheckValidator.swift`; the original
// megafile mixed three different validation concerns (dependency
// graph, pattern families, notebook checks) in 800+ LOC.

import Core
import Vapor

/// Validates the case key, uniqueness, and label fields of a pattern
/// family case.  Shared by every `PatternKind`.
private func validatePatternCaseHeader(
    family: PatternFamily, c: PatternCase, seenCaseKeys: inout Set<String>
) throws {
    guard isValidIdentifierFragment(c.key) else {
        throw Abort(
            .unprocessableEntity,
            reason:
                "Pattern family '\(family.id)': case key '\(c.key)' must contain only letters, digits, and underscore"
        )
    }
    // A function-calling family auto-generates an existence guard whose
    // filename uses `patternExistenceGuardCaseKey`; forbid a real case from
    // claiming that key so the two can never produce the same filename.
    if patternKindHandler(for: family.kind).requiresFunctionName,
        c.key == patternExistenceGuardCaseKey
    {
        throw Abort(
            .unprocessableEntity,
            reason:
                "Pattern family '\(family.id)': case key '\(c.key)' is reserved for the auto-generated existence guard; choose a different key."
        )
    }
    guard seenCaseKeys.insert(c.key).inserted else {
        throw Abort(
            .unprocessableEntity,
            reason: "Pattern family '\(family.id)': duplicate case key '\(c.key)'")
    }
    guard !c.label.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw Abort(
            .unprocessableEntity,
            reason: "Pattern family '\(family.id)': case '\(c.key)' is missing a label")
    }
}

/// Validates family-scoped variables (`PatternFamily.variables`) and any
/// `$name` arg references in `PatternCase.argVarRefs`.  Each variable
/// must be a valid identifier, unique within the family, and must not
/// collide with a parameter name.  `$name` refs must resolve to either
/// a family-level variable or one declared on the family's home
/// section.
private func validateFamilyVariablesAndArgRefs(
    family: PatternFamily,
    sectionVarNamesHere: Set<String>,
    globalVarNames: Set<String>,
    perStudentExpressionNames: Set<String>
) throws {
    var seenVarNames: Set<String> = []
    let paramNameSet = Set(family.paramNames)
    // Deliberately the CROSS-LANGUAGE SUBSET, not the assignment's grammar —
    // unlike `paramNames` and `.variableEquality`'s case variable, which this
    // release did widen.
    //
    // `isValidPythonIdentifier` is the predicate, but Python is not the reason,
    // and reading it that way points at the wrong fix. Two things pin it:
    //
    //  1. A family variable is REFERENCED from an arg cell as `$name`, parsed
    //     by `/^\$([A-Za-z_][A-Za-z0-9_]*)$/` in `pattern-family-editor.js`.
    //     Accepting a Racket `bmi-value` makes `$bmi-value` match nothing and
    //     fall through as a literal STRING — a wrong expected value in a
    //     generated test, reported nowhere.
    //  2. The name is EMITTED bare into the generated preamble. Every language
    //     has an emitter that makes an arbitrary name safe (`rIdentifier`
    //     backticks, `luaIdentifier`/`octaveIdentifier` mangle) EXCEPT Python,
    //     whose preamble writes `name = _ck["name"]` directly — so a hyphen is
    //     a syntax error. The subset is pinned by that weakest emitter.
    //
    // So the unlock is not "make this language-aware". It is: give Python an
    // emitter like the other four have, then widen the `$name` parser with it.
    // Same reasoning holds for global/section input names and `{{name}}`.
    for v in family.variables {
        guard isValidPythonIdentifier(v.name) else {
            throw Abort(
                .unprocessableEntity,
                reason: "Pattern family '\(family.id)': variable name '\(v.name)' is not a valid Python identifier")
        }
        guard seenVarNames.insert(v.name).inserted else {
            throw Abort(
                .unprocessableEntity,
                reason: "Pattern family '\(family.id)': duplicate variable name '\(v.name)'")
        }
        if paramNameSet.contains(v.name) {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)': variable name '\(v.name)' collides with a parameter name; the generated test would shadow the family variable."
            )
        }
    }
    for c in family.cases {
        for (i, maybeRef) in c.argVarRefs.enumerated() {
            guard let ref = maybeRef else { continue }
            // A `$name` ref resolves if the family declares the variable,
            // the family's home section does, it's an assignment-scope
            // global input, OR it's a per-student `=` expression (global or
            // section).  Literal refs are inlined at save time; per-student
            // refs are bound at grading time from `_ck_inputs.py`.  Only
            // "declared in none of these" is an error.
            let isPerStudent = perStudentExpressionNames.contains(ref)
            let isLiteralVar =
                seenVarNames.contains(ref) || sectionVarNamesHere.contains(ref)
                || globalVarNames.contains(ref)
            guard isPerStudent || isLiteralVar else {
                let paramLabel = (i < family.paramNames.count ? family.paramNames[i] : "arg \(i + 1)")
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Pattern family '\(family.id)': case '\(c.key)' arg '\(paramLabel)' references unknown variable '$\(ref)'"
                )
            }
            // Per-student arg refs are bound by the generated case's
            // personalization preamble, which only the equality kinds emit.
            if isPerStudent, !kindSupportsPerStudentArgRefs(family.kind) {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Pattern family '\(family.id)': case '\(c.key)' references per-student input '$\(ref)', which is only supported in \(perStudentArgCapableKindsDescription) families for now."
                )
            }
        }
        // A per-student expected ref must name a declared `=` expression and
        // is (for now) supported only in the equality kinds.
        if let eref = c.expectedVarRef {
            guard perStudentExpressionNames.contains(eref) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Pattern family '\(family.id)': case '\(c.key)' expected reference '$\(eref)' must name a per-student input (a global or section `=` expression)."
                )
            }
            guard kindSupportsPerStudentExpected(family.kind) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Pattern family '\(family.id)': case '\(c.key)' uses a per-student expected, which is only supported in \(perStudentExpectedCapableKindsDescription) families for now."
                )
            }
        }
    }
}

/// Whether a kind's generated cases can bind a per-student `$name` ARG ref.
/// Only the function-calling equality kinds can: they build a call from
/// `args`, so a bound name reaches the student's function.  `variableEquality`
/// cannot — its `args[0]` is the *name* of the variable to inspect, baked into
/// the script as a literal, so an arg ref there would be silently ignored
/// rather than personalizing anything.  An exhaustive switch — a new
/// `PatternKind` must opt in or out explicitly, and
/// `perStudentArgCapableKindsDescription` must name the same set.
private func kindSupportsPerStudentArgRefs(_ kind: PatternKind) -> Bool {
    switch kind {
    // `.differential` builds its call from `args` exactly as the equality
    // kinds do, so a bound name reaches both the student's function and the
    // reference — which is the point: the reference computes THIS student's
    // expected value rather than the author tabulating one per student.
    case .boundaryEquality, .approximateEquality, .unorderedEquality, .differential: return true
    case .variableEquality, .returnTypeCheck, .exceptionExpected,
        .performanceThreshold, .stdoutEquality:
        return false
    }
}

/// Whether a kind's generated cases can bind a per-student EXPECTED value.
/// This is a strictly weaker requirement than an arg ref: the case only needs
/// to emit the personalization preamble and read `expected` from it, which
/// every equality-shaped kind does.  `variableEquality` qualifies — "this
/// student's `sd_systolic` equals this student's expected value" is the
/// simplest personalization there is, and withholding it forced authors to
/// reshape a variable exercise into a function purely to get a per-student
/// answer.  Extend as renderers gain the preamble
/// (`personalizationPreambleForCase` / `rPersonalizationPreambleForCase`).
private func kindSupportsPerStudentExpected(_ kind: PatternKind) -> Bool {
    switch kind {
    case .boundaryEquality, .approximateEquality, .unorderedEquality, .variableEquality:
        return true
    // `.differential` authors no expected value at all — the reference
    // computes it — so there is nothing for a per-student expected ref to bind.
    case .returnTypeCheck, .exceptionExpected, .performanceThreshold, .stdoutEquality,
        .differential:
        return false
    }
}

/// Human-readable list of the kinds `kindSupportsPerStudentRefs` allows, for
/// validation error messages.  Keep in lockstep with the switch above.
private let perStudentArgCapableKindsDescription =
    "boundary_equality, approximate_equality, unordered_equality, and differential"

private let perStudentExpectedCapableKindsDescription =
    "boundary_equality, approximate_equality, unordered_equality, and variable_equality"

/// Validates the family `id`, `functionName`, and `paramNames` fields
/// — the structural header of one `PatternFamily` before its cases are
/// walked.  `seenFamilyIDs` is threaded through so duplicate-id
/// detection works across the whole list.
private func validatePatternFamilyHeader(
    family: PatternFamily,
    language: AssignmentLanguage,
    seenFamilyIDs: inout Set<String>
) throws {
    guard isValidIdentifierFragment(family.id) else {
        throw Abort(
            .unprocessableEntity,
            reason: "Pattern family id '\(family.id)' must contain only letters, digits, and underscore")
    }
    guard seenFamilyIDs.insert(family.id).inserted else {
        throw Abort(
            .unprocessableEntity,
            reason: "Duplicate pattern family id '\(family.id)'")
    }
    // `functionName` is ignored for kinds that inspect module-level state
    // rather than calling a function (`.variableEquality`), so skip the
    // identifier check for those — an empty or placeholder value is
    // acceptable.  Every function-calling kind still requires a valid
    // identifier.
    if patternKindHandler(for: family.kind).requiresFunctionName {
        guard isValidFunctionTarget(family.functionName, language: language) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)': functionName '\(family.functionName)' is not valid for a "
                    + "\(language.displayName) assignment — expected \(functionTargetExpectation(for: language))"
            )
        }
    }
    var seenParams: Set<String> = []
    for param in family.paramNames {
        guard isValidIdentifier(param, language: language) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)': parameter name '\(param)' is not a valid "
                    + identifierKindName(language))
        }
        guard seenParams.insert(param).inserted else {
            throw Abort(
                .unprocessableEntity,
                reason: "Pattern family '\(family.id)': duplicate parameter name '\(param)'")
        }
    }
}

/// Validates a list of pattern families before they are applied to a test
/// setup.  Called by `applyPatternFamilies` and from family CRUD endpoints.
///
/// Checks:
/// - family `id` is unique across the assignment, is a valid filename fragment,
///   and is a valid Python identifier (so it can appear in filenames).
/// - `functionName` is a valid Python identifier.
/// - every `paramName` is a valid Python identifier, and names are unique.
/// - within each family, `case.key` is unique and is a valid filename fragment.
/// - each case's `args.count` matches `paramNames.count` (when paramNames set).
/// - disabled cases participate in name/collision checks so a later toggle
///   doesn't spring a surprise.
/// - no generated filename collides with a hand-written script in `testSuites`
///   (raw entries are those with `generatedBy == nil`).
///
/// Per-family work is split into helpers (`validatePatternFamilyHeader`,
/// `validatePatternCaseHeader`, `validatePatternCaseKindSpecific`,
/// `validateFamilyVariablesAndArgRefs`); this top-level function
/// composes them and handles cross-family checks (filename collisions
/// against hand-written scripts).
func validatePatternFamilies(
    _ families: [PatternFamily],
    testSuites: [TestSuiteEntry],
    language: AssignmentLanguage,
    sections: [TestSuiteSection] = [],
    familySectionID: [String: String] = [:],
    globalVariableNames: Set<String> = [],
    perStudentExpressionNames: Set<String> = []
) throws {
    // v0.4.100: build a "extra names in scope for this family" set so
    // each family can reference its home section's variables too.
    let sectionVarsByID: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: sections.map { sec in
            (sec.id, Set(sec.variables.map(\.name)))
        }
    )
    // All section variable names across the manifest — used as the
    // permissive fallback when a family has no known home section yet
    // (i.e. it's a brand-new family being created via PUT /families
    // before the follow-up PUT /suite stamps its sectionID).  v0.4.108.
    // The strict per-section check still runs once the family is
    // placed: applyPatternFamilies is invoked again from the suite-
    // save path with `authoredItems` carrying the actual sectionID, so
    // a `$varInSectionY` ref on a family the user later drops into
    // section X correctly fails at suite-save time.
    let allSectionVarNames: Set<String> = sectionVarsByID.values.reduce(into: Set<String>()) {
        $0.formUnion($1)
    }
    func sectionVarNames(forFamily fid: String) -> Set<String> {
        if let sid = familySectionID[fid] {
            return sectionVarsByID[sid] ?? []
        }
        // No known section yet → permissive: accept any declared
        // section variable.  Strict check runs at suite-save.
        return allSectionVarNames
    }
    // 1. Per-family structural checks.
    var seenFamilyIDs: Set<String> = []
    for family in families {
        try validatePatternFamilyHeader(
            family: family, language: language, seenFamilyIDs: &seenFamilyIDs)

        let handler = patternKindHandler(for: family.kind)
        var seenCaseKeys: Set<String> = []
        for c in family.cases {
            try validatePatternCaseHeader(family: family, c: c, seenCaseKeys: &seenCaseKeys)
            try handler.validateCase(family: family, case: c, language: language)
        }

        // Family-level, kind-specific rules (e.g. approximateEquality's
        // non-negative tolerance bound).
        try handler.validateFamily(family)

        // v0.4.94: family-scoped variables.  Each name must be a valid
        // identifier, unique within the family, and not collide with a
        // parameter name (the renderer would shadow it at call time, silently
        // breaking the test).  Any `$name` reference in a case arg cell must
        // resolve to a declared variable — which is why these names, unlike
        // `paramNames`, stay on Python's grammar; see the helper.
        try validateFamilyVariablesAndArgRefs(
            family: family,
            sectionVarNamesHere: sectionVarNames(forFamily: family.id),
            globalVarNames: globalVariableNames,
            perStudentExpressionNames: perStudentExpressionNames
        )
    }

    // 2. Filename collisions: no generated filename may match a hand-written
    //    script's filename.  "Hand-written" = manifest entry with neither
    //    generator set (mirrors `TestSuiteEntry.isGenerated`).
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    // EVERY language's filenames, matching what the notebook-check collision
    // check beside this one already does (`notebookCheckFilenameCollisions`).
    // This asked only for Python's, so on an R assignment it compared
    // `publictest_bmi_01.py` against a suite full of `.R` scripts and could
    // never collide — the check was inert in five of the six languages. This
    // function has no language in scope and its callers have no reason to grow
    // one for a collision test: asking across `allCases` cannot miss, and the
    // only cost of the extra breadth is asking an instructor to rename a file
    // whose name a different language's rendering would have claimed.
    for family in families {
        let candidates = AssignmentLanguage.allCases.flatMap {
            patternFamilyAllGeneratedFilenames(family, language: $0)
        }
        for filename in candidates where rawScripts.contains(filename) {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' would generate '\(filename)', but a hand-written script with that name already exists. Rename the raw script or change the family id/case key."
            )
        }
    }
}

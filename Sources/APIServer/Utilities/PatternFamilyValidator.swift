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
    globalVarNames: Set<String>
) throws {
    var seenVarNames: Set<String> = []
    let paramNameSet = Set(family.paramNames)
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
            // the family's home section does, OR it's an assignment-scope
            // global input.  The renderer puts all three in scope
            // (`globalVariables + sectionVariables + family.variables`), so
            // accepting them here matches what actually renders — only
            // "declared in none of the three" is an error.  (Globals were
            // previously omitted from this set, which rejected the documented
            // `$global` worked example in docs/inputs.md.)
            guard
                seenVarNames.contains(ref) || sectionVarNamesHere.contains(ref)
                    || globalVarNames.contains(ref)
            else {
                let paramLabel = (i < family.paramNames.count ? family.paramNames[i] : "arg \(i + 1)")
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Pattern family '\(family.id)': case '\(c.key)' arg '\(paramLabel)' references unknown variable '$\(ref)'"
                )
            }
        }
    }
}

/// Validates the family `id`, `functionName`, and `paramNames` fields
/// — the structural header of one `PatternFamily` before its cases are
/// walked.  `seenFamilyIDs` is threaded through so duplicate-id
/// detection works across the whole list.
private func validatePatternFamilyHeader(
    family: PatternFamily,
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
        guard isValidPythonIdentifier(family.functionName) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)': functionName '\(family.functionName)' is not a valid Python identifier"
            )
        }
    }
    var seenParams: Set<String> = []
    for param in family.paramNames {
        guard isValidPythonIdentifier(param) else {
            throw Abort(
                .unprocessableEntity,
                reason: "Pattern family '\(family.id)': parameter name '\(param)' is not a valid Python identifier")
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
    sections: [TestSuiteSection] = [],
    familySectionID: [String: String] = [:],
    globalVariableNames: Set<String> = []
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
        try validatePatternFamilyHeader(family: family, seenFamilyIDs: &seenFamilyIDs)

        let handler = patternKindHandler(for: family.kind)
        var seenCaseKeys: Set<String> = []
        for c in family.cases {
            try validatePatternCaseHeader(family: family, c: c, seenCaseKeys: &seenCaseKeys)
            try handler.validateCase(family: family, case: c)
        }

        // Family-level, kind-specific rules (e.g. approximateEquality's
        // non-negative tolerance bound).
        try handler.validateFamily(family)

        // v0.4.94: family-scoped variables.  Each name must be a valid
        // Python identifier, unique within the family, and not collide
        // with a parameter name (the renderer would shadow it at call
        // time, silently breaking the test).  Any `$name` reference in
        // a case arg cell must resolve to a declared variable.
        try validateFamilyVariablesAndArgRefs(
            family: family,
            sectionVarNamesHere: sectionVarNames(forFamily: family.id),
            globalVarNames: globalVariableNames
        )
    }

    // 2. Filename collisions: no generated filename may match a hand-written
    //    script's filename.  "Hand-written" = manifest entry with neither
    //    generator set (mirrors `TestSuiteEntry.isGenerated`).
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    for family in families {
        for filename in patternFamilyAllGeneratedFilenames(family) where rawScripts.contains(filename) {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' would generate '\(filename)', but a hand-written script with that name already exists. Rename the raw script or change the family id/case key."
            )
        }
    }
}

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

// swiftlint:disable cyclomatic_complexity function_body_length
/// Validates the `args` / `expected` shape of a single case against its
/// family's `kind`.  Each branch corresponds to one `PatternKind`.
private func validatePatternCaseKindSpecific(family: PatternFamily, c: PatternCase) throws {
    switch family.kind {
    case .variableEquality:
        // Exactly one arg, which must be a non-empty string naming
        // the module-level variable to check.  `paramNames` is
        // ignored — for this kind it's purely a UI hint (column
        // header), not something the renderer or validator cares
        // about.
        guard c.args.count == 1 else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' must have exactly one arg (the variable name); got \(c.args.count)"
            )
        }
        guard case .string(let varName) = c.args[0],
            !varName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' arg must be a non-empty string (the variable name)"
            )
        }
        guard isValidPythonIdentifier(varName) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' variable name '\(varName)' is not a valid Python identifier"
            )
        }
    case .boundaryEquality, .approximateEquality:
        if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)': case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
            )
        }
    case .returnTypeCheck:
        if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (return_type_check): case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
            )
        }
        guard case .string(let expectedType) = c.expected,
            !expectedType.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (return_type_check): case '\(c.key)' expected must be a non-empty string naming the type (e.g. \"int\", \"DataFrame\")"
            )
        }
    case .exceptionExpected:
        if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (exception_expected): case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
            )
        }
        guard case .string(let exceptionType) = c.expected,
            !exceptionType.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (exception_expected): case '\(c.key)' expected must be a non-empty string naming the exception class (e.g. \"ValueError\")"
            )
        }
    case .performanceThreshold:
        if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (performance_threshold): case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
            )
        }
        let threshold: Double? = {
            switch c.expected {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }()
        guard let t = threshold, t.isFinite, t > 0 else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (performance_threshold): case '\(c.key)' expected must be a positive number (milliseconds)"
            )
        }
    case .stdoutEquality:
        if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (stdout_equality): case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
            )
        }
        // Empty string is intentionally allowed — it means "this
        // function should print nothing", a legitimate case for
        // a beginner exercise where the assignment is to add the
        // print() call.
        guard case .string = c.expected else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (stdout_equality): case '\(c.key)' expected must be a string (the captured stdout to match)"
            )
        }
    }
}
// swiftlint:enable cyclomatic_complexity function_body_length

/// Validates family-scoped variables (`PatternFamily.variables`) and any
/// `$name` arg references in `PatternCase.argVarRefs`.  Each variable
/// must be a valid identifier, unique within the family, and must not
/// collide with a parameter name.  `$name` refs must resolve to either
/// a family-level variable or one declared on the family's home
/// section.
private func validateFamilyVariablesAndArgRefs(
    family: PatternFamily,
    sectionVarNamesHere: Set<String>
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
            // v0.4.100: a `$name` ref resolves if EITHER the family
            // declares the variable OR the family's home section
            // does.  Family-level shadows section-level at render
            // time — so both are valid refs; only "declared in
            // neither" is an error.
            guard seenVarNames.contains(ref) || sectionVarNamesHere.contains(ref) else {
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
    // `functionName` is ignored for .variableEquality families (they
    // check module-level variables, not function calls), so skip the
    // identifier check in that case — an empty or placeholder value is
    // acceptable.  Every other kind still requires a valid identifier.
    if family.kind != .variableEquality {
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
    familySectionID: [String: String] = [:]
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

        var seenCaseKeys: Set<String> = []
        for c in family.cases {
            try validatePatternCaseHeader(family: family, c: c, seenCaseKeys: &seenCaseKeys)
            try validatePatternCaseKindSpecific(family: family, c: c)
        }

        // Kind-specific rules: approximateEquality needs a non-negative tolerance.
        if family.kind == .approximateEquality {
            if let tol = family.defaults.tolerance, tol < 0 || !tol.isFinite {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Pattern family '\(family.id)': tolerance must be a non-negative finite number.")
            }
        }

        // v0.4.94: family-scoped variables.  Each name must be a valid
        // Python identifier, unique within the family, and not collide
        // with a parameter name (the renderer would shadow it at call
        // time, silently breaking the test).  Any `$name` reference in
        // a case arg cell must resolve to a declared variable.
        try validateFamilyVariablesAndArgRefs(
            family: family,
            sectionVarNamesHere: sectionVarNames(forFamily: family.id)
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

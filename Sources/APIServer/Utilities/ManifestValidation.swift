// APIServer/Utilities/ManifestValidation.swift
//
// Validates the dependency graph and pattern-family spec in a TestProperties
// manifest.

import Core
import Vapor

/// Validates families + dependency graph in one call.  Throws
/// `Abort(.unprocessableEntity)` with a student-friendly reason on any
/// structural problem.
func validateManifest(_ manifest: TestProperties) throws {
    // Pass section data through so family cases that reference section-
    // level `$variables` (v0.4.100) validate correctly.  Map each family
    // to its section by finding the sectionID on its first generated
    // testSuites entry; families with no generated entries default to
    // no section (no extra variable names in scope).
    var familySectionID: [String: String] = [:]
    for entry in manifest.testSuites {
        if let fid = entry.generatedBy, let sid = entry.sectionID, familySectionID[fid] == nil {
            familySectionID[fid] = sid
        }
    }
    try validatePatternFamilies(
        manifest.patternFamilies,
        testSuites: manifest.testSuites,
        sections: manifest.sections,
        familySectionID: familySectionID
    )
    try validateNotebookChecks(
        manifest.notebookChecks,
        patternFamilies: manifest.patternFamilies,
        testSuites: manifest.testSuites
    )
    try validateManifestDependencies(manifest)
}

/// Validates the `dependsOn` references and dependency graph in a manifest.
///
/// Throws an `Abort(.unprocessableEntity)` if:
/// - Any `dependsOn` entry names a script that does not exist in `testSuites`.
/// - The dependency graph contains a cycle.
func validateManifestDependencies(_ manifest: TestProperties) throws {
    let allScripts = Set(manifest.testSuites.map(\.script))

    // 1. Reference check — every name in dependsOn must be a known script.
    for entry in manifest.testSuites {
        for dep in entry.dependsOn {
            guard allScripts.contains(dep) else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Manifest dependency error: '\(entry.script)' depends on '\(dep)', which is not listed in testSuites"
                )
            }
            guard dep != entry.script else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Manifest dependency error: '\(entry.script)' cannot depend on itself"
                )
            }
        }
    }

    // 2. Cycle detection via DFS (Kahn-style).
    //    Build adjacency list: script → scripts that depend on it.
    var inDegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]  // prerequisite → [scripts that need it]
    for entry in manifest.testSuites {
        inDegree[entry.script, default: 0] += 0  // ensure every node is present
        for dep in entry.dependsOn {
            dependents[dep, default: []].append(entry.script)
            inDegree[entry.script, default: 0] += 1
        }
    }

    var queue = inDegree.filter { $0.value == 0 }.map(\.key)
    var processed = 0
    while !queue.isEmpty {
        let node = queue.removeLast()
        processed += 1
        for dependent in dependents[node, default: []] {
            inDegree[dependent, default: 0] -= 1
            if inDegree[dependent, default: 0] == 0 {
                queue.append(dependent)
            }
        }
    }

    guard processed == manifest.testSuites.count else {
        throw Abort(
            .unprocessableEntity,
            reason: "Manifest dependency error: dependency graph contains a cycle"
        )
    }
}

/// Validates a list of pattern families before they are applied to a test
/// setup.  Called by `validateManifest` and also directly from family CRUD
/// endpoints when rendering a preview.
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
    /// All section variable names across the manifest — used as the
    /// permissive fallback when a family has no known home section yet
    /// (i.e. it's a brand-new family being created via PUT /families
    /// before the follow-up PUT /suite stamps its sectionID).  v0.4.108.
    /// The strict per-section check still runs once the family is
    /// placed: applyPatternFamilies is invoked again from the suite-
    /// save path with `authoredItems` carrying the actual sectionID, so
    /// a `$varInSectionY` ref on a family the user later drops into
    /// section X correctly fails at suite-save time.
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
        guard isValidIdentifierFragment(family.id) else {
            throw Abort(.unprocessableEntity,
                reason: "Pattern family id '\(family.id)' must contain only letters, digits, and underscore")
        }
        guard seenFamilyIDs.insert(family.id).inserted else {
            throw Abort(.unprocessableEntity,
                reason: "Duplicate pattern family id '\(family.id)'")
        }
        // `functionName` is ignored for .variableEquality families (they
        // check module-level variables, not function calls), so skip the
        // identifier check in that case — an empty or placeholder value is
        // acceptable.  Every other kind still requires a valid identifier.
        if family.kind != .variableEquality {
            guard isValidPythonIdentifier(family.functionName) else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': functionName '\(family.functionName)' is not a valid Python identifier")
            }
        }
        var seenParams: Set<String> = []
        for param in family.paramNames {
            guard isValidPythonIdentifier(param) else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': parameter name '\(param)' is not a valid Python identifier")
            }
            guard seenParams.insert(param).inserted else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': duplicate parameter name '\(param)'")
            }
        }

        var seenCaseKeys: Set<String> = []
        for c in family.cases {
            guard isValidIdentifierFragment(c.key) else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': case key '\(c.key)' must contain only letters, digits, and underscore")
            }
            guard seenCaseKeys.insert(c.key).inserted else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': duplicate case key '\(c.key)'")
            }
            guard !c.label.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': case '\(c.key)' is missing a label")
            }
            switch family.kind {
            case .variableEquality:
                // Exactly one arg, which must be a non-empty string naming
                // the module-level variable to check.  `paramNames` is
                // ignored — for this kind it's purely a UI hint (column
                // header), not something the renderer or validator cares
                // about.
                guard c.args.count == 1 else {
                    throw Abort(.unprocessableEntity,
                        reason: "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' must have exactly one arg (the variable name); got \(c.args.count)")
                }
                guard case .string(let varName) = c.args[0],
                      !varName.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw Abort(.unprocessableEntity,
                        reason: "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' arg must be a non-empty string (the variable name)")
                }
                guard isValidPythonIdentifier(varName) else {
                    throw Abort(.unprocessableEntity,
                        reason: "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' variable name '\(varName)' is not a valid Python identifier")
                }
            case .boundaryEquality, .approximateEquality:
                if !family.paramNames.isEmpty, c.args.count != family.paramNames.count {
                    throw Abort(.unprocessableEntity,
                        reason: "Pattern family '\(family.id)': case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)")
                }
            }
        }

        // Kind-specific rules: approximateEquality needs a non-negative tolerance.
        if family.kind == .approximateEquality {
            if let tol = family.defaults.tolerance, tol < 0 || !tol.isFinite {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': tolerance must be a non-negative finite number.")
            }
        }

        // v0.4.94: family-scoped variables.  Each name must be a valid
        // Python identifier, unique within the family, and not collide
        // with a parameter name (the renderer would shadow it at call
        // time, silently breaking the test).  Any `$name` reference in
        // a case arg cell must resolve to a declared variable.
        var seenVarNames: Set<String> = []
        let paramNameSet = Set(family.paramNames)
        for v in family.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': variable name '\(v.name)' is not a valid Python identifier")
            }
            guard seenVarNames.insert(v.name).inserted else {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': duplicate variable name '\(v.name)'")
            }
            if paramNameSet.contains(v.name) {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)': variable name '\(v.name)' collides with a parameter name; the generated test would shadow the family variable.")
            }
        }
        let sectionVarNamesHere = sectionVarNames(forFamily: family.id)
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
                    throw Abort(.unprocessableEntity,
                        reason: "Pattern family '\(family.id)': case '\(c.key)' arg '\(paramLabel)' references unknown variable '$\(ref)'")
                }
            }
        }
    }

    // 2. Filename collisions: no generated filename may match a hand-written
    //    script's filename.  "Hand-written" = manifest entry with neither
    //    generator set (mirrors `TestSuiteEntry.isGenerated`).
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    for family in families {
        for filename in patternFamilyAllGeneratedFilenames(family) {
            if rawScripts.contains(filename) {
                throw Abort(.unprocessableEntity,
                    reason: "Pattern family '\(family.id)' would generate '\(filename)', but a hand-written script with that name already exists. Rename the raw script or change the family id/case key.")
            }
        }
    }
}

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
func validateNotebookChecks(
    _ checks: [NotebookCheck],
    patternFamilies: [PatternFamily] = [],
    testSuites: [TestSuiteEntry] = []
) throws {
    var seenCheckIDs: Set<String> = []
    for check in checks {
        guard isValidIdentifierFragment(check.id) else {
            throw Abort(.unprocessableEntity,
                reason: "Notebook check id '\(check.id)' must contain only letters, digits, and underscore")
        }
        guard seenCheckIDs.insert(check.id).inserted else {
            throw Abort(.unprocessableEntity,
                reason: "Duplicate notebook check id '\(check.id)'")
        }
        guard check.points >= 0 else {
            throw Abort(.unprocessableEntity,
                reason: "Notebook check '\(check.id)': points must be non-negative")
        }

        switch check.kind {
        case .dataFrameShape:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_shape): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_shape): variable name '\(variable)' is not a valid Python identifier")
            }
            guard let rows = check.expectedRows, rows >= 0 else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_shape): expectedRows must be a non-negative integer")
            }
            guard let cols = check.expectedCols, cols >= 0 else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_shape): expectedCols must be a non-negative integer")
            }

        case .dataFrameColumns:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_columns): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_columns): variable name '\(variable)' is not a valid Python identifier")
            }
            guard let columns = check.expectedColumns, !columns.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_columns): expectedColumns must be a non-empty list")
            }
            for col in columns {
                guard !col.isEmpty else {
                    throw Abort(.unprocessableEntity,
                        reason: "Notebook check '\(check.id)' (data_frame_columns): expectedColumns contains an empty entry")
                }
            }
            // Under .exact, duplicate column names render an unsatisfiable
            // expected (pandas DataFrames technically allow duplicate
            // labels but it's a foot-gun for graded assignments).  Catch
            // it at save time.
            if (check.columnMatch ?? .exact) == .exact,
               Set(columns).count != columns.count {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_columns): expectedColumns contains duplicate names under exact matching")
            }

        case .dataFrameEquality:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): variable name '\(variable)' is not a valid Python identifier")
            }
            guard let csv = check.expectedCSV, !csv.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): expectedCSV must be a non-empty CSV string")
            }
            // Quick sanity: the first line should look like a header (one
            // or more comma-separated tokens or a single non-empty
            // token).  This catches the case of an instructor pasting
            // `pd.DataFrame(...)` Python code instead of CSV.
            let firstLine = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? ""
            guard !firstLine.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): expectedCSV must begin with a header row")
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): atol must be a non-negative finite number")
            }

        case .seriesEquality:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): variable name '\(variable)' is not a valid Python identifier")
            }
            guard let csv = check.expectedCSV, !csv.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): expectedCSV must be a non-empty CSV string")
            }
            // Single-column header check: the first line should not
            // contain a comma (a multi-column CSV would be ambiguous
            // — which column is the Series?).
            let firstLine = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? ""
            guard !firstLine.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): expectedCSV must begin with a header row")
            }
            if firstLine.contains(",") {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): expectedCSV must have exactly one column (header had a comma)")
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): atol must be a non-negative finite number")
            }

        case .numericArrayClose:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): variable name '\(variable)' is not a valid Python identifier")
            }
            guard let array = check.expectedArray, !array.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): expectedArray must be a non-empty list of numbers")
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): atol must be a non-negative finite number")
            }

        case .figureCount:
            guard let n = check.minFigures, n >= 0 else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (figure_count): minFigures must be a non-negative integer")
            }

        case .cellContains:
            guard let needle = check.containsText, !needle.isEmpty else {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (cell_contains): containsText must be a non-empty string")
            }
            // If regex, sanity-check that it compiles.  We can't run a
            // Python regex from Swift, but a simple parser catches the
            // most common typos (unbalanced parens, dangling `\`).
            if check.regex == true {
                let openParens = needle.filter { $0 == "(" }.count
                let closeParens = needle.filter { $0 == ")" }.count
                guard openParens == closeParens else {
                    throw Abort(.unprocessableEntity,
                        reason: "Notebook check '\(check.id)' (cell_contains): regex has unbalanced parentheses")
                }
                if needle.hasSuffix("\\") {
                    throw Abort(.unprocessableEntity,
                        reason: "Notebook check '\(check.id)' (cell_contains): regex ends with a dangling backslash")
                }
            }
        }
    }

    // Filename collisions: every generated filename a check produces
    // (its test script + any sidecars like `_expected_<id>.csv`) must
    // not match a hand-written script or a pattern-family-generated
    // filename.  A future pattern family might generate the same name
    // as a future check; this catches that at save time so the runner
    // never sees a duplicate.
    let rawScripts = Set(testSuites.filter { !$0.isGenerated }.map(\.script))
    let familyFilenames = Set(patternFamilies.flatMap(patternFamilyAllGeneratedFilenames))
    var seenCheckFilenames: Set<String> = []
    for check in checks {
        for filename in notebookCheckAllGeneratedFilenames(check) {
            if rawScripts.contains(filename) {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' would generate '\(filename)', but a hand-written file with that name already exists. Rename the file or change the check id.")
            }
            if familyFilenames.contains(filename) {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' would generate '\(filename)', which collides with a pattern family's generated filename. Change the check id.")
            }
            if !seenCheckFilenames.insert(filename).inserted {
                throw Abort(.unprocessableEntity,
                    reason: "Notebook check '\(check.id)' would generate '\(filename)', which collides with another check's generated file. Change the check id.")
            }
        }
    }
}

private let pythonKeywords: Set<String> = [
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "class", "continue", "def", "del", "elif", "else", "except", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"
]

func isValidPythonIdentifier(_ s: String) -> Bool {
    guard !s.isEmpty, !pythonKeywords.contains(s) else { return false }
    let chars = Array(s)
    let first = chars[0]
    guard first.isLetter || first == "_" else { return false }
    for ch in chars.dropFirst() {
        guard ch.isLetter || ch.isNumber || ch == "_" else { return false }
    }
    return true
}

/// Stricter than Python identifier: lowercase-preferred alphanumeric + underscore,
/// allowed to start with a digit (for case keys like "01").  Used to validate
/// filename-fragment safety.
private func isValidIdentifierFragment(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

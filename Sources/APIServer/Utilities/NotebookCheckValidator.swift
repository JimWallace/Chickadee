// APIServer/Utilities/NotebookCheckValidator.swift
//
// Validates a list of `NotebookCheck` records before they are applied
// to a test setup.  Mirrors `PatternFamilyValidator.swift` for the
// parallel concept.  Split out of `ManifestValidation.swift` in
// v0.4.182.

import Core
import Vapor

// swiftlint:disable cyclomatic_complexity function_body_length
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
/// Body is long for the same reason as `validatePatternFamilies` above:
/// it does the full schema validation pass for every `NotebookCheck`
/// kind (existence, dataframe shape, value equality, etc.), and the
/// per-kind rules are easier to follow inline than threaded through
/// kind-specific helper functions.
func validateNotebookChecks(
    _ checks: [NotebookCheck],
    patternFamilies: [PatternFamily] = [],
    testSuites: [TestSuiteEntry] = []
) throws {
    var seenCheckIDs: Set<String> = []
    for check in checks {
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

        switch check.kind {
        case .dataFrameShape:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_shape): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_shape): variable name '\(variable)' is not a valid Python identifier"
                )
            }
            guard let rows = check.expectedRows, rows >= 0 else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_shape): expectedRows must be a non-negative integer")
            }
            guard let cols = check.expectedCols, cols >= 0 else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_shape): expectedCols must be a non-negative integer")
            }

        case .dataFrameColumns:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_columns): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_columns): variable name '\(variable)' is not a valid Python identifier"
                )
            }
            guard let columns = check.expectedColumns, !columns.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_columns): expectedColumns must be a non-empty list")
            }
            for col in columns {
                guard !col.isEmpty else {
                    throw Abort(
                        .unprocessableEntity,
                        reason:
                            "Notebook check '\(check.id)' (data_frame_columns): expectedColumns contains an empty entry"
                    )
                }
            }
            // Under .exact, duplicate column names render an unsatisfiable
            // expected (pandas DataFrames technically allow duplicate
            // labels but it's a foot-gun for graded assignments).  Catch
            // it at save time.
            if (check.columnMatch ?? .exact) == .exact,
                Set(columns).count != columns.count
            {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_columns): expectedColumns contains duplicate names under exact matching"
                )
            }

        case .dataFrameEquality:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (data_frame_equality): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_equality): variable name '\(variable)' is not a valid Python identifier"
                )
            }
            guard let csv = check.expectedCSV, !csv.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_equality): expectedCSV must be a non-empty CSV string"
                )
            }
            // Quick sanity: the first line should look like a header (one
            // or more comma-separated tokens or a single non-empty
            // token).  This catches the case of an instructor pasting
            // `pd.DataFrame(...)` Python code instead of CSV.
            let firstLine = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? ""
            guard !firstLine.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_equality): expectedCSV must begin with a header row")
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_equality): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (data_frame_equality): atol must be a non-negative finite number")
            }

        case .seriesEquality:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (series_equality): variable name '\(variable)' is not a valid Python identifier"
                )
            }
            guard let csv = check.expectedCSV, !csv.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): expectedCSV must be a non-empty CSV string"
                )
            }
            // Single-column header check: the first line should not
            // contain a comma (a multi-column CSV would be ambiguous
            // — which column is the Series?).
            let firstLine = csv.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? ""
            guard !firstLine.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): expectedCSV must begin with a header row")
            }
            if firstLine.contains(",") {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (series_equality): expectedCSV must have exactly one column (header had a comma)"
                )
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (series_equality): atol must be a non-negative finite number")
            }

        case .numericArrayClose:
            guard let variable = check.variable, !variable.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (numeric_array_close): variable name is required")
            }
            guard isValidPythonIdentifier(variable) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (numeric_array_close): variable name '\(variable)' is not a valid Python identifier"
                )
            }
            guard let array = check.expectedArray, !array.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (numeric_array_close): expectedArray must be a non-empty list of numbers"
                )
            }
            if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (numeric_array_close): rtol must be a non-negative finite number")
            }
            if let atol = check.atol, !atol.isFinite || atol < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (numeric_array_close): atol must be a non-negative finite number")
            }

        case .figureCount:
            guard let n = check.minFigures, n >= 0 else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (figure_count): minFigures must be a non-negative integer")
            }

        case .cellContains:
            guard let needle = check.containsText, !needle.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (cell_contains): containsText must be a non-empty string")
            }
            // If regex, sanity-check that it compiles.  We can't run a
            // Python regex from Swift, but a simple parser catches the
            // most common typos (unbalanced parens, dangling `\`).
            if check.regex == true {
                let openParens = needle.filter { $0 == "(" }.count
                let closeParens = needle.filter { $0 == ")" }.count
                guard openParens == closeParens else {
                    throw Abort(
                        .unprocessableEntity,
                        reason: "Notebook check '\(check.id)' (cell_contains): regex has unbalanced parentheses")
                }
                if needle.hasSuffix("\\") {
                    throw Abort(
                        .unprocessableEntity,
                        reason: "Notebook check '\(check.id)' (cell_contains): regex ends with a dangling backslash")
                }
            }

        case .functionExists:
            guard let name = check.variable, !name.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (function_exists): function name (variable) is required")
            }
            guard isValidPythonIdentifier(name) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (function_exists): function name '\(name)' is not a valid Python identifier"
                )
            }
            if let arity = check.expectedArity, arity < 0 {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (function_exists): expectedArity must be non-negative")
            }

        case .variableExists:
            guard let name = check.variable, !name.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (variable_exists): variable name is required")
            }
            guard isValidPythonIdentifier(name) else {
                throw Abort(
                    .unprocessableEntity,
                    reason:
                        "Notebook check '\(check.id)' (variable_exists): variable name '\(name)' is not a valid Python identifier"
                )
            }
            // expectedType (if present) must be non-empty and non-whitespace.
            // Unknown type names fall through to the renderer's MRO-walk
            // fallback (same behaviour as `.returnTypeCheck`), so we don't
            // need a known-name allowlist here.
            if let typeName = check.expectedType {
                let trimmed = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw Abort(
                        .unprocessableEntity,
                        reason:
                            "Notebook check '\(check.id)' (variable_exists): expectedType must be a non-empty type name when set (e.g. \"int\", \"list\", \"DataFrame\")"
                    )
                }
            }

        case .astStructure:
            guard let constructs = check.requiredConstructs, !constructs.isEmpty else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Notebook check '\(check.id)' (ast_structure): requiredConstructs must be a non-empty list")
            }
            let knownPredicates: Set<String> = [
                "for_loop", "while_loop", "list_comprehension", "lambda", "recursion",
            ]
            for raw in constructs {
                let predicate = raw.hasPrefix("!") ? String(raw.dropFirst()) : raw
                if predicate.hasPrefix("import:") {
                    let mod = String(predicate.dropFirst("import:".count))
                    guard !mod.isEmpty,
                        mod.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
                    else {
                        throw Abort(
                            .unprocessableEntity,
                            reason:
                                "Notebook check '\(check.id)' (ast_structure): import predicate '\(raw)' has an invalid module name"
                        )
                    }
                    continue
                }
                guard knownPredicates.contains(predicate) else {
                    throw Abort(
                        .unprocessableEntity,
                        reason:
                            "Notebook check '\(check.id)' (ast_structure): unknown predicate '\(raw)' — supported: for_loop, while_loop, list_comprehension, lambda, recursion, import:<module>, optional leading `!` for negation"
                    )
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
// swiftlint:enable cyclomatic_complexity function_body_length

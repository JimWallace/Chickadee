// APIServer/Utilities/NotebookCheckKindHandler.swift
//
// Per-kind behaviour for `NotebookCheckKind`, captured behind one protocol
// with a single conforming type per case.  Replaces the parallel
// `switch check.kind` sites that used to live in `NotebookCheckRenderer`
// (sidecar-filename listing + render/label/sidecar dispatch) and
// `NotebookCheckValidator` (per-kind field validation) — adding or changing a
// kind now means touching one handler plus the `notebookCheckKindHandler(for:)`
// resolver, and a new `NotebookCheckKind` case fails to compile until the
// resolver's exhaustive switch gains an entry.
//
// The `NotebookCheckKind` enum stays the Codable wire format unchanged; these
// handlers are pure dispatch and never serialised.  Render and label bodies
// still live in `NotebookCheckRenderer+{Code,DataFrame,Plots}.swift`; each
// handler delegates to the matching function so generated script bytes — and
// therefore every `spec_hash` and `TestSetupCache` key — stay identical.

import Core
import Vapor

/// Behaviour for one `NotebookCheckKind`: how a check renders to Python, its
/// auto-generated display label, any sidecar files it emits, and how it is
/// validated before being applied to a test setup.
protocol NotebookCheckKindHandler: Sendable {
    /// Renders the check's Python test script.  Delegates to the matching
    /// `render*` function.
    func render(_ check: NotebookCheck, specHash: String) -> String

    /// Auto-generated display name used when the check has no explicit `name`.
    func defaultLabel(_ check: NotebookCheck) -> String

    /// Sidecar files (filename → contents) this kind writes alongside its
    /// test script.  Default: none.
    func sidecars(_ check: NotebookCheck) -> [String: String]

    /// Validates the kind-specific required fields. `language` selects the
    /// identifier grammar for name fields (Python vs R) so an R assignment's
    /// idiomatic names (`my.df`) aren't held to Python's rules.
    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws
}

extension NotebookCheckKindHandler {
    func sidecars(_ check: NotebookCheck) -> [String: String] { [:] }
}

/// Resolves a `NotebookCheckKind` to its handler.  The exhaustive switch is
/// the single dispatch point: a new enum case fails to compile here until a
/// handler is wired in, restoring the compile-time guarantee the per-site
/// `switch check.kind` statements used to provide.
func notebookCheckKindHandler(for kind: NotebookCheckKind) -> any NotebookCheckKindHandler {
    switch kind {
    case .dataFrameShape: return DataFrameShapeKind()
    case .dataFrameColumns: return DataFrameColumnsKind()
    case .dataFrameEquality: return DataFrameEqualityKind()
    case .seriesEquality: return SeriesEqualityKind()
    case .numericArrayClose: return NumericArrayCloseKind()
    case .figureCount: return FigureCountKind()
    case .cellContains: return CellContainsKind()
    case .functionExists: return FunctionExistsKind()
    case .variableExists: return VariableExistsKind()
    case .astStructure: return ASTStructureKind()
    }
}

// MARK: - Shared validation helpers

/// The "variable name is a required, valid Python identifier" check shared by
/// every kind that inspects a named module-level value.  `kindLabel` is the
/// `(kind_name)` infix and `field` names the offending field in the message
/// (some kinds call it a "variable name", `.functionExists` a "function name").
private func validateRequiredIdentifier(
    _ value: String?, check: NotebookCheck, kindLabel: String, field: String,
    language: AssignmentLanguage
) throws -> String {
    guard let value, !value.isEmpty else {
        throw Abort(
            .unprocessableEntity,
            reason: "Notebook check '\(check.id)' (\(kindLabel)): \(field) is required")
    }
    guard isValidIdentifier(value, language: language) else {
        throw Abort(
            .unprocessableEntity,
            reason:
                "Notebook check '\(check.id)' (\(kindLabel)): \(field) '\(value)' is not a valid \(identifierKindName(language))"
        )
    }
    return value
}

/// Identifier grammar for `language`. Keeps name fields (`variable`, function
/// names) held to the right language's rules, so an R name like `my.df` passes
/// on an R assignment while Python assignments are unchanged.
private func isValidIdentifier(_ value: String, language: AssignmentLanguage) -> Bool {
    switch language {
    case .python: return isValidPythonIdentifier(value)
    case .r: return isValidRIdentifier(value)
    }
}

/// Human-readable name of the identifier grammar, for validation messages.
private func identifierKindName(_ language: AssignmentLanguage) -> String {
    switch language {
    case .python: return "Python identifier"
    case .r: return "R name"
    }
}

/// rtol / atol bounds check shared by the float-comparison kinds.
private func validateTolerances(_ check: NotebookCheck, kindLabel: String) throws {
    if let rtol = check.rtol, !rtol.isFinite || rtol < 0 {
        throw Abort(
            .unprocessableEntity,
            reason: "Notebook check '\(check.id)' (\(kindLabel)): rtol must be a non-negative finite number")
    }
    if let atol = check.atol, !atol.isFinite || atol < 0 {
        throw Abort(
            .unprocessableEntity,
            reason: "Notebook check '\(check.id)' (\(kindLabel)): atol must be a non-negative finite number")
    }
}

/// Cheap sanity scan for a user-supplied `cell_contains` regex needle.  A full
/// Python/R regex engine isn't available from Swift, so this only catches the
/// common typos: unbalanced parentheses and a dangling trailing backslash.  It
/// walks the pattern tracking escape state and character-class nesting, so an
/// escaped `\(`, a literal `[(]`, or a literal `\\` at the end isn't
/// miscounted — the bug this replaced compared raw `(`/`)` character counts and
/// tested `hasSuffix("\\")`, both of which mis-flagged those cases.
private func validateRegexSanity(_ needle: String, checkID: String) throws {
    func unbalanced() -> Abort {
        Abort(
            .unprocessableEntity,
            reason: "Notebook check '\(checkID)' (cell_contains): regex has unbalanced parentheses")
    }
    var depth = 0
    var inClass = false
    var escaped = false
    for ch in needle {
        if escaped {
            escaped = false
            continue
        }
        switch ch {
        case "\\": escaped = true
        case "[" where !inClass: inClass = true
        case "]" where inClass: inClass = false
        case "(" where !inClass: depth += 1
        case ")" where !inClass:
            guard depth > 0 else { throw unbalanced() }
            depth -= 1
        default: break
        }
    }
    if escaped {
        throw Abort(
            .unprocessableEntity,
            reason: "Notebook check '\(checkID)' (cell_contains): regex ends with a dangling backslash")
    }
    guard depth == 0 else { throw unbalanced() }
}

// MARK: - dataFrameShape

struct DataFrameShapeKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderDataFrameShape(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultDataFrameShapeLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "data_frame_shape", field: "variable name", language: language)
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
    }
}

// MARK: - dataFrameColumns

struct DataFrameColumnsKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderDataFrameColumns(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultDataFrameColumnsLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "data_frame_columns", field: "variable name", language: language)
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
    }
}

// MARK: - dataFrameEquality

struct DataFrameEqualityKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderDataFrameEquality(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultDataFrameEqualityLabel(check) }

    func sidecars(_ check: NotebookCheck) -> [String: String] {
        [expectedCSVSidecarFilename(checkID: check.id): check.expectedCSV ?? ""]
    }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "data_frame_equality", field: "variable name", language: language)
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
        try validateTolerances(check, kindLabel: "data_frame_equality")
    }
}

// MARK: - seriesEquality

struct SeriesEqualityKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderSeriesEquality(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultSeriesEqualityLabel(check) }

    func sidecars(_ check: NotebookCheck) -> [String: String] {
        [expectedCSVSidecarFilename(checkID: check.id): check.expectedCSV ?? ""]
    }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "series_equality", field: "variable name", language: language)
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
        try validateTolerances(check, kindLabel: "series_equality")
    }
}

// MARK: - numericArrayClose

struct NumericArrayCloseKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderNumericArrayClose(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultNumericArrayCloseLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "numeric_array_close", field: "variable name", language: language)
        guard let array = check.expectedArray, !array.isEmpty else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Notebook check '\(check.id)' (numeric_array_close): expectedArray must be a non-empty list of numbers"
            )
        }
        try validateTolerances(check, kindLabel: "numeric_array_close")
    }
}

// MARK: - figureCount

struct FigureCountKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderFigureCount(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultFigureCountLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        guard let n = check.minFigures, n >= 0 else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)' (figure_count): minFigures must be a non-negative integer")
        }
    }
}

// MARK: - cellContains

struct CellContainsKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderCellContains(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultCellContainsLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        guard let needle = check.containsText, !needle.isEmpty else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)' (cell_contains): containsText must be a non-empty string")
        }
        // If regex, sanity-check that it compiles.  We can't run a Python/R
        // regex from Swift, but a small scan catches the most common typos.
        if check.regex == true {
            try validateRegexSanity(needle, checkID: check.id)
        }
    }
}

// MARK: - functionExists

struct FunctionExistsKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderFunctionExists(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultFunctionExistsLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        // Inlined rather than routed through `validateRequiredIdentifier`:
        // this kind's two messages historically used different field
        // wording ("function name (variable)" when missing, "function
        // name" when the identifier is malformed); preserve both verbatim.
        guard let name = check.variable, !name.isEmpty else {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)' (function_exists): function name (variable) is required")
        }
        guard isValidIdentifier(name, language: language) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Notebook check '\(check.id)' (function_exists): function name '\(name)' is not a valid \(identifierKindName(language))"
            )
        }
        if let arity = check.expectedArity, arity < 0 {
            throw Abort(
                .unprocessableEntity,
                reason: "Notebook check '\(check.id)' (function_exists): expectedArity must be non-negative")
        }
    }
}

// MARK: - variableExists

struct VariableExistsKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderVariableExists(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultVariableExistsLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
        _ = try validateRequiredIdentifier(
            check.variable, check: check, kindLabel: "variable_exists", field: "variable name", language: language)
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
    }
}

// MARK: - astStructure

struct ASTStructureKind: NotebookCheckKindHandler {
    func render(_ check: NotebookCheck, specHash: String) -> String {
        renderASTStructure(check, specHash: specHash)
    }
    func defaultLabel(_ check: NotebookCheck) -> String { defaultASTStructureLabel(check) }

    func validate(_ check: NotebookCheck, language: AssignmentLanguage) throws {
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

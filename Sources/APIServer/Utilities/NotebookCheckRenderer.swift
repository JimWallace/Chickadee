// APIServer/Utilities/NotebookCheckRenderer.swift
//
// Expands a NotebookCheck into a single deterministic Python test script,
// optionally with sidecar files (e.g. `_expected_<id>.csv` for
// `.dataFrameEquality`).  Mirrors PatternFamilyRenderer's contract:
// pure function, byte-stable output for byte-stable input, generated
// source uses test_runtime helpers so the runner can't tell it apart
// from a hand-authored script.

import Foundation
import Crypto
import Core

/// Stable filename for one check's test script.  Format:
/// `{tier}check_{checkID}.py`.  The "check_" infix distinguishes from
/// pattern-family files ("test_") so a glance at the zip listing tells
/// you which generator produced the file; the runner doesn't care.
func generatedCheckFilename(checkID: String, tier: TestTier) -> String {
    "\(tierFilenamePrefixForCheck(tier))check_\(checkID).py"
}

/// Stable filename for a check's expected-data sidecar CSV.  Used by
/// `.dataFrameEquality` and `.seriesEquality`.  Leading underscore keeps
/// it out of the way alphabetically and avoids collision with
/// instructor-bundled or student-uploaded data files.
func expectedCSVSidecarFilename(checkID: String) -> String {
    "_expected_\(checkID).csv"
}

/// One check's full output: the test script plus zero or more sidecar
/// files (filename → contents).  The apply path writes both into the
/// test setup zip in a single mutation pass and tracks all filenames
/// for the diff/delete cycle.
struct GeneratedCheck: Equatable {
    let script: GeneratedScript
    let sidecars: [String: String]
}

/// All filenames a check **would** produce (script + sidecars).  Used
/// when diffing old/new specs so stale sidecars get cleaned up alongside
/// the test scripts.  Mirrors `patternFamilyAllGeneratedFilenames`.
func notebookCheckAllGeneratedFilenames(_ check: NotebookCheck) -> [String] {
    var out = [generatedCheckFilename(checkID: check.id, tier: check.tier)]
    switch check.kind {
    case .dataFrameShape, .dataFrameColumns, .numericArrayClose:
        break  // no sidecars
    case .dataFrameEquality, .seriesEquality:
        out.append(expectedCSVSidecarFilename(checkID: check.id))
    }
    return out
}

/// Top-level entry point.  Returns the test script plus any sidecar
/// files the kind needs.
func renderNotebookCheck(_ check: NotebookCheck) -> GeneratedCheck {
    let hash = notebookCheckSpecHash(check)
    let source: String
    let displayName: String
    var sidecars: [String: String] = [:]
    switch check.kind {
    case .dataFrameShape:
        source      = renderDataFrameShape(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameShapeLabel(check)
    case .dataFrameColumns:
        source      = renderDataFrameColumns(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameColumnsLabel(check)
    case .dataFrameEquality:
        source      = renderDataFrameEquality(check, specHash: hash)
        displayName = check.name ?? defaultDataFrameEqualityLabel(check)
        sidecars[expectedCSVSidecarFilename(checkID: check.id)] =
            check.expectedCSV ?? ""
    case .seriesEquality:
        source      = renderSeriesEquality(check, specHash: hash)
        displayName = check.name ?? defaultSeriesEqualityLabel(check)
        sidecars[expectedCSVSidecarFilename(checkID: check.id)] =
            check.expectedCSV ?? ""
    case .numericArrayClose:
        source      = renderNumericArrayClose(check, specHash: hash)
        displayName = check.name ?? defaultNumericArrayCloseLabel(check)
    }

    let script = GeneratedScript(
        filename:    generatedCheckFilename(checkID: check.id, tier: check.tier),
        source:      source,
        tier:        check.tier,
        points:      check.points,
        displayName: displayName,
        caseKey:     "",          // unused for checks; one file per check
        familyID:    ""           // unused for checks; the route field is generatedByCheck
    )
    return GeneratedCheck(script: script, sidecars: sidecars)
}

/// 16-character hex prefix of a SHA-256 over the check spec.  Stable for a
/// given spec; bust the manifest cache when anything about the check
/// changes.  Mirrors `patternFamilySpecHash`.
func notebookCheckSpecHash(_ check: NotebookCheck) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(check)) ?? Data()
    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(16))
}

// MARK: - .dataFrameShape

private func defaultDataFrameShapeLabel(_ check: NotebookCheck) -> String {
    let v = check.variable ?? "df"
    let r = check.expectedRows.map(String.init) ?? "?"
    let c = check.expectedCols.map(String.init) ?? "?"
    return "\(v) shape (\(r), \(c))"
}

private func renderDataFrameShape(_ check: NotebookCheck, specHash: String) -> String {
    // Validation guarantees these are present, but fall back to safe
    // sentinels so the rendered Python is at least syntactically valid
    // when called outside the validated path (e.g. unit tests).
    let variable     = check.variable     ?? "df"
    let expectedRows = check.expectedRows ?? 0
    let expectedCols = check.expectedCols ?? 0
    let label        = check.name ?? defaultDataFrameShapeLabel(check)

    let variableLiteral = "\"" + escapeForPythonStringLiteralCheck(variable) + "\""

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=data_frame_shape spec_hash=\(specHash) — edit the check, not this file.

    variable_name = \(variableLiteral)
    expected_shape = (\(expectedRows), \(expectedCols))

    _MISSING = object()
    actual = getattr(student_module, variable_name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined in the student notebook.\\n"
            f"  expected: a DataFrame with shape {expected_shape}\\n"
        )

    shape = getattr(actual, "shape", None)
    if shape is None:
        failed(
            f"Variable `{variable_name}` is not a DataFrame.\\n"
            f"  expected: a DataFrame with shape {expected_shape}\\n"
            f"  got:      {type(actual).__name__}\\n"
        )

    try:
        actual_shape = tuple(int(d) for d in shape)
    except Exception:
        failed(
            f"Variable `{variable_name}` has an unreadable shape `{shape!r}`.\\n"
            f"  expected: a DataFrame with shape {expected_shape}\\n"
        )

    if actual_shape != expected_shape:
        failed(
            f"Variable `{variable_name}` has the wrong shape.\\n"
            f"  expected: {expected_shape}\\n"
            f"  got:      {actual_shape}\\n"
        )

    passed(f"`{variable_name}` has shape {actual_shape}")
    """
}

// MARK: - .dataFrameColumns

private func defaultDataFrameColumnsLabel(_ check: NotebookCheck) -> String {
    let v = check.variable ?? "df"
    let count = check.expectedColumns?.count ?? 0
    let mode = check.columnMatch ?? .exact
    switch mode {
    case .exact:    return "\(v) columns (exact, \(count))"
    case .superset: return "\(v) columns (≥ \(count))"
    }
}

private func renderDataFrameColumns(_ check: NotebookCheck, specHash: String) -> String {
    let variable = check.variable ?? "df"
    let columns  = check.expectedColumns ?? []
    let mode     = check.columnMatch ?? .exact
    let label    = check.name ?? defaultDataFrameColumnsLabel(check)

    let variableLiteral = "\"" + escapeForPythonStringLiteralCheck(variable) + "\""
    let expectedLiteral = "[" + columns.map { c in
        "\"" + escapeForPythonStringLiteralCheck(c) + "\""
    }.joined(separator: ", ") + "]"

    let comparisonBlock: String
    switch mode {
    case .exact:
        comparisonBlock = """
        if list(actual_columns) != expected_columns:
            failed(
                f"Variable `{variable_name}` has the wrong columns (exact match required).\\n"
                f"  expected: {expected_columns}\\n"
                f"  got:      {list(actual_columns)}\\n"
            )

        passed(f"`{variable_name}` columns match exactly")
        """
    case .superset:
        comparisonBlock = """
        missing = [c for c in expected_columns if c not in set(actual_columns)]
        if missing:
            failed(
                f"Variable `{variable_name}` is missing required columns.\\n"
                f"  expected (subset): {expected_columns}\\n"
                f"  got:               {list(actual_columns)}\\n"
                f"  missing:           {missing}\\n"
            )

        passed(f"`{variable_name}` contains all {len(expected_columns)} required column(s)")
        """
    }

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=data_frame_columns spec_hash=\(specHash) — edit the check, not this file.

    variable_name = \(variableLiteral)
    expected_columns = \(expectedLiteral)

    _MISSING = object()
    actual = getattr(student_module, variable_name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined in the student notebook.\\n"
            f"  expected columns: {expected_columns}\\n"
        )

    actual_columns = getattr(actual, "columns", None)
    if actual_columns is None:
        failed(
            f"Variable `{variable_name}` is not a DataFrame (no .columns attribute).\\n"
            f"  expected columns: {expected_columns}\\n"
            f"  got:              {type(actual).__name__}\\n"
        )

    \(comparisonBlock)
    """
}

// MARK: - .dataFrameEquality

private func defaultDataFrameEqualityLabel(_ check: NotebookCheck) -> String {
    "\(check.variable ?? "df") matches expected DataFrame"
}

private func renderDataFrameEquality(_ check: NotebookCheck, specHash: String) -> String {
    let variable    = check.variable ?? "df"
    let label       = check.name ?? defaultDataFrameEqualityLabel(check)
    let csvFilename = expectedCSVSidecarFilename(checkID: check.id)

    let checkDtype  = check.checkDtype  ?? true
    let checkLike   = check.checkLike   ?? false
    let ignoreIndex = check.ignoreIndex ?? true

    let variableLiteral    = "\"" + escapeForPythonStringLiteralCheck(variable) + "\""
    let csvFilenameLiteral = "\"" + escapeForPythonStringLiteralCheck(csvFilename) + "\""

    // Tolerance kwargs are only emitted when set; pandas' defaults (rtol=1e-5,
    // atol=1e-8) cover the typical case and changing them per-test is rare.
    var assertKwargs: [String] = [
        "check_dtype=\(checkDtype ? "True" : "False")",
        "check_like=\(checkLike ? "True" : "False")",
    ]
    if let rtol = check.rtol { assertKwargs.append("rtol=\(rtol)") }
    if let atol = check.atol { assertKwargs.append("atol=\(atol)") }
    let assertKwargsLine = assertKwargs.joined(separator: ",\n            ")

    // Two index-handling modes.  `ignoreIndex` (default true) resets both
    // sides to a fresh RangeIndex before the assertion — the right
    // behaviour when students reset_index after a groupby or load CSV
    // without index_col.  `ignoreIndex == false` compares as-is, so an
    // assignment that explicitly grades an index can opt in.
    let indexNormalisation: String
    if ignoreIndex {
        indexNormalisation = """
        actual_cmp = actual.reset_index(drop=True)
        expected_cmp = expected.reset_index(drop=True)
        """
    } else {
        indexNormalisation = """
        actual_cmp = actual
        expected_cmp = expected
        """
    }

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=data_frame_equality spec_hash=\(specHash) — edit the check, not this file.

    import pandas as pd

    variable_name = \(variableLiteral)

    try:
        expected = pd.read_csv(\(csvFilenameLiteral))
    except Exception as ex:
        errored(f"Could not load expected DataFrame from \(csvFilename): {ex}")

    _MISSING = object()
    actual = getattr(student_module, variable_name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined in the student notebook.\\n"
            f"  expected a DataFrame with shape {expected.shape} and columns {list(expected.columns)}\\n"
        )

    if not isinstance(actual, pd.DataFrame):
        failed(
            f"Variable `{variable_name}` is not a DataFrame.\\n"
            f"  expected: a DataFrame with shape {expected.shape}\\n"
            f"  got:      {type(actual).__name__}\\n"
        )

    \(indexNormalisation)

    try:
        pd.testing.assert_frame_equal(
            actual_cmp,
            expected_cmp,
            \(assertKwargsLine)
        )
    except AssertionError as ex:
        # pandas' assert_frame_equal raises with a useful diff in `ex`.
        # Surface it directly along with shape/column context so the
        # student can see the structural mismatch at a glance.
        failed(
            f"Variable `{variable_name}` does not match expected.\\n"
            f"  expected shape: {expected.shape}\\n"
            f"  got shape:      {actual.shape}\\n"
            f"  expected cols:  {list(expected.columns)}\\n"
            f"  got cols:       {list(actual.columns)}\\n"
            f"\\n{ex}"
        )

    passed(f"`{variable_name}` matches expected DataFrame")
    """
}

// MARK: - .seriesEquality

private func defaultSeriesEqualityLabel(_ check: NotebookCheck) -> String {
    "\(check.variable ?? "series") matches expected Series"
}

private func renderSeriesEquality(_ check: NotebookCheck, specHash: String) -> String {
    let variable    = check.variable ?? "series"
    let label       = check.name ?? defaultSeriesEqualityLabel(check)
    let csvFilename = expectedCSVSidecarFilename(checkID: check.id)

    let checkDtype  = check.checkDtype  ?? true
    let ignoreIndex = check.ignoreIndex ?? true

    let variableLiteral    = "\"" + escapeForPythonStringLiteralCheck(variable) + "\""
    let csvFilenameLiteral = "\"" + escapeForPythonStringLiteralCheck(csvFilename) + "\""

    var assertKwargs: [String] = [
        "check_dtype=\(checkDtype ? "True" : "False")",
    ]
    if let rtol = check.rtol { assertKwargs.append("rtol=\(rtol)") }
    if let atol = check.atol { assertKwargs.append("atol=\(atol)") }
    let assertKwargsLine = assertKwargs.joined(separator: ",\n            ")

    let indexNormalisation: String
    if ignoreIndex {
        indexNormalisation = """
        actual_cmp = actual.reset_index(drop=True)
        expected_cmp = expected.reset_index(drop=True)
        """
    } else {
        indexNormalisation = """
        actual_cmp = actual
        expected_cmp = expected
        """
    }

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=series_equality spec_hash=\(specHash) — edit the check, not this file.

    import pandas as pd

    variable_name = \(variableLiteral)

    try:
        # Single-column CSV → Series via squeeze().  Falls back to the
        # first column if pandas returns a DataFrame (multi-column CSV
        # is rejected by the validator at save time).
        _expected_frame = pd.read_csv(\(csvFilenameLiteral))
        expected = _expected_frame.squeeze("columns")
        if not isinstance(expected, pd.Series):
            expected = _expected_frame.iloc[:, 0]
    except Exception as ex:
        errored(f"Could not load expected Series from \(csvFilename): {ex}")

    _MISSING = object()
    actual = getattr(student_module, variable_name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined in the student notebook.\\n"
            f"  expected a Series of length {len(expected)}\\n"
        )

    if not isinstance(actual, pd.Series):
        failed(
            f"Variable `{variable_name}` is not a Series.\\n"
            f"  expected: a Series of length {len(expected)}\\n"
            f"  got:      {type(actual).__name__}\\n"
        )

    \(indexNormalisation)

    try:
        pd.testing.assert_series_equal(
            actual_cmp,
            expected_cmp,
            \(assertKwargsLine)
        )
    except AssertionError as ex:
        failed(
            f"Variable `{variable_name}` does not match expected Series.\\n"
            f"  expected length: {len(expected)}\\n"
            f"  got length:      {len(actual)}\\n"
            f"\\n{ex}"
        )

    passed(f"`{variable_name}` matches expected Series")
    """
}

// MARK: - .numericArrayClose

private func defaultNumericArrayCloseLabel(_ check: NotebookCheck) -> String {
    "\(check.variable ?? "array") matches expected (numeric tolerance)"
}

private func renderNumericArrayClose(_ check: NotebookCheck, specHash: String) -> String {
    let variable = check.variable      ?? "array"
    let label    = check.name          ?? defaultNumericArrayCloseLabel(check)
    let expected = check.expectedArray ?? []

    let variableLiteral = "\"" + escapeForPythonStringLiteralCheck(variable) + "\""
    let expectedLiteral = "[" + expected.map { numericArrayLiteral($0) }.joined(separator: ", ") + "]"

    var assertKwargs: [String] = []
    if let rtol = check.rtol { assertKwargs.append("rtol=\(rtol)") }
    if let atol = check.atol { assertKwargs.append("atol=\(atol)") }
    let assertKwargsLine = assertKwargs.isEmpty
        ? ""
        : ",\n            " + assertKwargs.joined(separator: ",\n            ")

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=numeric_array_close spec_hash=\(specHash) — edit the check, not this file.

    import numpy as np

    variable_name = \(variableLiteral)
    expected = np.array(\(expectedLiteral), dtype=float)

    _MISSING = object()
    actual_obj = getattr(student_module, variable_name, _MISSING)
    if actual_obj is _MISSING:
        failed(
            f"Variable `{variable_name}` is not defined in the student notebook.\\n"
            f"  expected an array of length {len(expected)}\\n"
        )

    try:
        actual = np.asarray(actual_obj, dtype=float)
    except Exception as ex:
        failed(
            f"Variable `{variable_name}` could not be coerced to a numeric array.\\n"
            f"  got: {type(actual_obj).__name__}\\n"
            f"  error: {type(ex).__name__}: {ex}\\n"
        )

    if actual.shape != expected.shape:
        failed(
            f"Variable `{variable_name}` has the wrong shape.\\n"
            f"  expected: {expected.shape}\\n"
            f"  got:      {actual.shape}\\n"
        )

    try:
        np.testing.assert_allclose(
            actual,
            expected\(assertKwargsLine)
        )
    except AssertionError as ex:
        failed(
            f"Variable `{variable_name}` is not close enough to expected.\\n"
            f"\\n{ex}"
        )

    passed(f"`{variable_name}` is close to expected (length {len(expected)})")
    """
}

/// Renders a Double as a Python literal that round-trips cleanly into
/// a numpy array.  NaN / inf get the explicit `float('nan')` / `inf`
/// spellings so the array constructor accepts them; finite numbers use
/// Swift's default Double description (which preserves precision).
private func numericArrayLiteral(_ value: Double) -> String {
    if value.isNaN { return #"float("nan")"# }
    if value.isInfinite {
        return value > 0 ? #"float("inf")"# : #"float("-inf")"#
    }
    return "\(value)"
}

// MARK: - Helpers

private func tierFilenamePrefixForCheck(_ tier: TestTier) -> String {
    switch tier {
    case .pub:     return "public"
    case .release: return "release"
    case .secret:  return "secret"
    }
}

/// Same semantics as `PatternFamilyRenderer.escapeForPythonStringLiteral`,
/// duplicated locally so the two renderers stay independent.  Tiny
/// function, churn-free.
private func escapeForPythonStringLiteralCheck(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\x%02x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

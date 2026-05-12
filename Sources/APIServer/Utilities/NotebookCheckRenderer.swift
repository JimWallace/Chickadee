// APIServer/Utilities/NotebookCheckRenderer.swift
//
// Expands a NotebookCheck into a single deterministic Python test script,
// optionally with sidecar files (e.g. `_expected_<id>.csv` for
// `.dataFrameEquality`).  Mirrors PatternFamilyRenderer's contract:
// pure function, byte-stable output for byte-stable input, generated
// source uses test_runtime helpers so the runner can't tell it apart
// from a hand-authored script.

import Foundation
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
    case .dataFrameShape, .dataFrameColumns, .numericArrayClose,
         .figureCount, .cellContains, .functionExists,
         .variableExists, .astStructure:
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
    case .figureCount:
        source      = renderFigureCount(check, specHash: hash)
        displayName = check.name ?? defaultFigureCountLabel(check)
    case .cellContains:
        source      = renderCellContains(check, specHash: hash)
        displayName = check.name ?? defaultCellContainsLabel(check)
    case .functionExists:
        source      = renderFunctionExists(check, specHash: hash)
        displayName = check.name ?? defaultFunctionExistsLabel(check)
    case .variableExists:
        source      = renderVariableExists(check, specHash: hash)
        displayName = check.name ?? defaultVariableExistsLabel(check)
    case .astStructure:
        source      = renderASTStructure(check, specHash: hash)
        displayName = check.name ?? defaultASTStructureLabel(check)
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
    return String(sha256HexDigest(data).prefix(16))
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

// MARK: - .figureCount

private func defaultFigureCountLabel(_ check: NotebookCheck) -> String {
    let n = check.minFigures ?? 1
    return "Notebook produces ≥ \(n) figure\(n == 1 ? "" : "s")"
}

private func renderFigureCount(_ check: NotebookCheck, specHash: String) -> String {
    let minFigures = check.minFigures ?? 1
    let label      = check.name ?? defaultFigureCountLabel(check)

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=figure_count spec_hash=\(specHash) — edit the check, not this file.

    minimum = \(minFigures)

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as ex:
        errored(f"matplotlib is not available in the grading environment: {ex}")

    # plt.get_fignums() reads matplotlib's global Figure registry.  By the
    # time this script runs, test_runtime.py has already loaded the student
    # module, which executed every plt.figure / df.plot / sns.* call the
    # student wrote — those Figure objects are still in the registry even
    # though plt.show was a no-op.
    figure_count = len(plt.get_fignums())

    if figure_count < minimum:
        failed(
            f"Student notebook produced too few figures.\\n"
            f"  expected at least: {minimum}\\n"
            f"  got:               {figure_count}\\n"
        )

    passed(f"Student notebook produced {figure_count} figure(s) (minimum {minimum})")
    """
}

// MARK: - .cellContains

private func defaultCellContainsLabel(_ check: NotebookCheck) -> String {
    let needle = check.containsText ?? ""
    let preview = needle.count > 30 ? String(needle.prefix(27)) + "..." : needle
    return "Notebook contains `\(preview)`"
}

private func renderCellContains(_ check: NotebookCheck, specHash: String) -> String {
    let needle = check.containsText ?? ""
    let asRegex = check.regex ?? false
    let mustDiffer = check.mustDifferFrom
    let label = check.name ?? defaultCellContainsLabel(check)

    let needleLiteral = "\"" + escapeForPythonStringLiteralCheck(needle) + "\""
    let mustDifferLiteral: String
    if let mustDiffer {
        mustDifferLiteral = "\"" + escapeForPythonStringLiteralCheck(mustDiffer) + "\""
    } else {
        mustDifferLiteral = "None"
    }

    let matchExpr = asRegex
        ? "re.search(needle, src) is not None"
        : "needle in src"

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=cell_contains spec_hash=\(specHash) — edit the check, not this file.

    import json
    import re
    from pathlib import Path

    needle = \(needleLiteral)
    must_differ_from = \(mustDifferLiteral)

    # SubmissionNormalizer (v0.4.114+) writes a copy of the original
    # student notebook to `_submission.ipynb` next to the flattened .py
    # student module, so source-level checks like this one have
    # cell-by-cell visibility that the flattened .py loses.
    notebook_path = Path("_submission.ipynb")
    if not notebook_path.exists():
        errored(
            "Student notebook source not preserved — cannot run cell-content check.\\n"
            "  expected: _submission.ipynb in workspace\\n"
        )

    try:
        notebook = json.loads(notebook_path.read_text(encoding="utf-8"))
    except Exception as ex:
        errored(f"Could not parse _submission.ipynb: {ex}")

    code_cells = []
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        src = cell.get("source", "")
        if isinstance(src, list):
            src = "".join(src)
        code_cells.append(src)

    matched_cells = []
    for src in code_cells:
        if \(matchExpr):
            matched_cells.append(src)

    if not matched_cells:
        failed(
            f"No code cell in the notebook matches `{needle}`.\\n"
            f"  expected: at least one cell containing the pattern\\n"
            f"  searched: {len(code_cells)} code cell(s)\\n"
        )

    if must_differ_from is not None:
        # Whitespace-normalize both sides so trailing newlines / leading
        # indentation differences don't mask a near-identical match.
        def _normalize(s):
            return " ".join(s.split())
        ref = _normalize(must_differ_from)
        only_identical = all(_normalize(src) == ref for src in matched_cells)
        if only_identical:
            failed(
                f"Cell containing `{needle}` is identical to the example.\\n"
                f"  expected: a cell that contains `{needle}` AND differs from the example\\n"
                f"  hint:     write your own version, not a copy of the prompt's example\\n"
            )

    passed(f"Found {len(matched_cells)} cell(s) containing `{needle}`")
    """
}

// MARK: - .functionExists

private func defaultFunctionExistsLabel(_ check: NotebookCheck) -> String {
    let name = check.variable ?? "function"
    if let arity = check.expectedArity {
        return "`\(name)` is defined and takes \(arity) arg\(arity == 1 ? "" : "s")"
    }
    return "`\(name)` is defined and callable"
}

private func renderFunctionExists(_ check: NotebookCheck, specHash: String) -> String {
    let name  = check.variable ?? "function"
    let label = check.name ?? defaultFunctionExistsLabel(check)
    let nameLiteral = "\"" + escapeForPythonStringLiteralCheck(name) + "\""

    let arityCheck: String
    if let arity = check.expectedArity {
        arityCheck = """
        # Compare against required + optional positional params (with
        # leniency for *args).  Mirrors test_runtime.py's _require_num_args.
        try:
            sig = inspect.signature(fn)
        except (TypeError, ValueError):
            sig = None
        if sig is not None:
            positional_kinds = {
                inspect.Parameter.POSITIONAL_ONLY,
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
            }
            params = [p for p in sig.parameters.values() if p.kind in positional_kinds]
            required = sum(1 for p in params if p.default is inspect.Parameter.empty)
            total = len(params)
            accepts_varargs = any(
                p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values()
            )
            expected_arity = \(arity)
            if accepts_varargs:
                if expected_arity < required:
                    failed(
                        f"`{name}` requires at least {required} positional argument(s) "
                        f"but the test expected it to take {expected_arity}."
                    )
            elif not (required <= expected_arity <= total):
                if required == total:
                    failed(
                        f"`{name}` should take {expected_arity} argument(s), "
                        f"but it takes {total}."
                    )
                else:
                    failed(
                        f"`{name}` should take {expected_arity} argument(s), "
                        f"but it takes {required}-{total}."
                    )
        """
    } else {
        arityCheck = "# (no arity check; existence + callability only)"
    }

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=function_exists spec_hash=\(specHash) — edit the check, not this file.

    import inspect

    name = \(nameLiteral)

    _MISSING = object()
    fn = getattr(student_module, name, _MISSING)
    if fn is _MISSING:
        failed(
            f"`{name}` is not defined in the student notebook.\\n"
            f"  expected: a callable named `{name}`\\n"
        )

    if not callable(fn):
        failed(
            f"`{name}` is defined but not callable.\\n"
            f"  got: {type(fn).__name__}\\n"
        )

    \(arityCheck)

    passed(f"`{name}` is defined and callable")
    """
}

// MARK: - .variableExists

private func defaultVariableExistsLabel(_ check: NotebookCheck) -> String {
    let name = check.variable ?? "variable"
    if let typeName = check.expectedType, !typeName.isEmpty {
        return "`\(name)` is defined and is a \(typeName)"
    }
    return "`\(name)` is defined"
}

/// Maps an instructor-typed Python type name to a runtime check
/// expression against an arbitrary value variable.  Mirrors
/// `PatternFamilyRenderer.returnTypeCheckExpression` byte-for-byte
/// (parameterised by the value variable so we don't have to import a
/// shared helper; the comment at the bottom of this file calls out the
/// duplication convention).  Builtins use `isinstance` directly; library
/// types are matched by walking the MRO by class name so we don't have to
/// import pandas/numpy at the top of the generated test.
private func variableExistsTypeCheckExpression(typeName: String, valueExpr: String) -> String {
    switch typeName {
    case "int":      return "isinstance(\(valueExpr), int) and not isinstance(\(valueExpr), bool)"
    case "float":    return "isinstance(\(valueExpr), float)"
    case "bool":     return "isinstance(\(valueExpr), bool)"
    case "str":      return "isinstance(\(valueExpr), str)"
    case "list":     return "isinstance(\(valueExpr), list)"
    case "tuple":    return "isinstance(\(valueExpr), tuple)"
    case "dict":     return "isinstance(\(valueExpr), dict)"
    case "set":      return "isinstance(\(valueExpr), set)"
    case "NoneType": return "\(valueExpr) is None"
    case "DataFrame":
        return #"any(getattr(b, "__name__", "") == "DataFrame" for b in type(\#(valueExpr)).__mro__)"#
    case "Series":
        return #"any(getattr(b, "__name__", "") == "Series" for b in type(\#(valueExpr)).__mro__)"#
    case "ndarray":
        return #"any(getattr(b, "__name__", "") == "ndarray" for b in type(\#(valueExpr)).__mro__)"#
    default:
        // Fallback: treat the name as a class to MRO-walk.  Catches
        // student-defined classes referenced by name and lets new
        // library types work without a Swift edit.
        return "any(getattr(b, \"__name__\", \"\") == \"\(typeName)\" for b in type(\(valueExpr)).__mro__)"
    }
}

private func renderVariableExists(_ check: NotebookCheck, specHash: String) -> String {
    let name  = check.variable ?? "variable"
    let label = check.name ?? defaultVariableExistsLabel(check)
    let nameLiteral = "\"" + escapeForPythonStringLiteralCheck(name) + "\""

    let typeCheck: String
    let passMessage: String
    if let typeName = check.expectedType, !typeName.isEmpty {
        let typeNameLiteral = "\"" + escapeForPythonStringLiteralCheck(typeName) + "\""
        let typeCheckExpr = variableExistsTypeCheckExpression(typeName: typeName, valueExpr: "actual")
        typeCheck = """
        expected_type_name = \(typeNameLiteral)
        if not (\(typeCheckExpr)):
            failed(
                f"Variable `{name}` has the wrong type.\\n"
                f"  expected: {expected_type_name}\\n"
                f"  got:      {type(actual).__name__}\\n"
            )
        """
        passMessage = #"f"`{name}` is defined and is a {expected_type_name}""#
    } else {
        typeCheck = "# (no type check; existence only)"
        passMessage = #"f"`{name}` is defined""#
    }

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=variable_exists spec_hash=\(specHash) — edit the check, not this file.

    name = \(nameLiteral)

    _MISSING = object()
    actual = getattr(student_module, name, _MISSING)
    if actual is _MISSING:
        failed(
            f"Variable `{name}` is not defined in the student notebook.\\n"
            f"  expected: a module-level variable named `{name}`\\n"
        )

    \(typeCheck)

    passed(\(passMessage))
    """
}

// MARK: - .astStructure

private func defaultASTStructureLabel(_ check: NotebookCheck) -> String {
    let constructs = check.requiredConstructs ?? []
    if constructs.isEmpty { return "Notebook AST structure" }
    let preview = constructs.prefix(3).joined(separator: ", ")
    let suffix = constructs.count > 3 ? ", …" : ""
    return "Notebook uses \(preview)\(suffix)"
}

private func renderASTStructure(_ check: NotebookCheck, specHash: String) -> String {
    let constructs = check.requiredConstructs ?? []
    let label = check.name ?? defaultASTStructureLabel(check)

    let constructsLiteral = "[" + constructs.map { c in
        "\"" + escapeForPythonStringLiteralCheck(c) + "\""
    }.joined(separator: ", ") + "]"

    return """
    # Test: \(label)
    # Generated from notebook check "\(escapeForPythonStringLiteralCheck(check.id))" kind=ast_structure spec_hash=\(specHash) — edit the check, not this file.

    import ast
    import json
    from pathlib import Path

    required = \(constructsLiteral)

    # SubmissionNormalizer (v0.4.114+) preserves the original notebook
    # alongside the flattened .py.  Walk every code cell's AST and
    # check for the listed constructs.
    notebook_path = Path("_submission.ipynb")
    if not notebook_path.exists():
        errored(
            "Student notebook source not preserved — cannot run AST structure check.\\n"
            "  expected: _submission.ipynb in workspace\\n"
        )

    try:
        notebook = json.loads(notebook_path.read_text(encoding="utf-8"))
    except Exception as ex:
        errored(f"Could not parse _submission.ipynb: {ex}")

    sources = []
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        src = cell.get("source", "")
        if isinstance(src, list):
            src = "".join(src)
        # Strip Jupyter magics so ast.parse doesn't choke on `%pip` etc.
        kept = []
        for line in src.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("%") or stripped.startswith("!"):
                continue
            kept.append(line)
        sources.append("\\n".join(kept))

    # Parse every cell.  Cells that fail to parse are skipped silently —
    # student syntax errors will already trip other tests.
    trees = []
    for src in sources:
        try:
            trees.append(ast.parse(src))
        except Exception:
            continue

    def has_node_type(node_class):
        for tree in trees:
            for node in ast.walk(tree):
                if isinstance(node, node_class):
                    return True
        return False

    def has_import(module_name):
        for tree in trees:
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        if alias.name == module_name or alias.name.startswith(module_name + "."):
                            return True
                elif isinstance(node, ast.ImportFrom):
                    if (node.module or "") == module_name or (node.module or "").startswith(module_name + "."):
                        return True
        return False

    def has_recursion():
        # Heuristic: a function that calls itself by name in its body.
        # Catches the common case (def foo: ... foo(...)) without
        # tripping on every passive `foo()` reference outside foo.
        for tree in trees:
            for node in ast.walk(tree):
                if not isinstance(node, ast.FunctionDef):
                    continue
                fn_name = node.name
                for inner in ast.walk(node):
                    if (isinstance(inner, ast.Call)
                        and isinstance(inner.func, ast.Name)
                        and inner.func.id == fn_name):
                        return True
        return False

    def evaluate(predicate):
        # Returns True if the predicate holds across all parsed cells.
        if predicate.startswith("import:"):
            return has_import(predicate.split(":", 1)[1])
        if predicate == "for_loop":
            return has_node_type(ast.For)
        if predicate == "while_loop":
            return has_node_type(ast.While)
        if predicate == "list_comprehension":
            return has_node_type(ast.ListComp)
        if predicate == "lambda":
            return has_node_type(ast.Lambda)
        if predicate == "recursion":
            return has_recursion()
        # Unknown predicate — fail rather than silently passing, so the
        # instructor notices a typo at grading time.
        failed(f"Unknown AST predicate `{predicate}` — supported: for_loop, while_loop, list_comprehension, lambda, recursion, import:<module>")

    failures = []
    for raw in required:
        negate = raw.startswith("!")
        predicate = raw[1:] if negate else raw
        actual = evaluate(predicate)
        expected = not negate
        if actual != expected:
            verb = "must NOT use" if negate else "must use"
            failures.append(f"{verb} {predicate}")

    if failures:
        failed(
            "structural requirements not met\\n"
            f"  failed: {'; '.join(failures)}\\n"
        )

    passed(f"All {len(required)} AST predicate(s) satisfied")
    """
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

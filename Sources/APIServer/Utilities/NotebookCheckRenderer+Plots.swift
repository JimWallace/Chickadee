// APIServer/Utilities/NotebookCheckRenderer+Plots.swift
//
// Numerical-array and structural check renderers (.numericArrayClose, .figureCount, .cellContains).
// Split from NotebookCheckRenderer.swift for navigability.

import Core
import Foundation

// MARK: - .numericArrayClose

func defaultNumericArrayCloseLabel(_ check: NotebookCheck) -> String {
    "\(check.variable ?? "array") matches expected (numeric tolerance)"
}

func renderNumericArrayClose(_ check: NotebookCheck, specHash: String) -> String {
    let variable = check.variable ?? "array"
    let label = check.name ?? defaultNumericArrayCloseLabel(check)
    let expected = check.expectedArray ?? []

    let variableLiteral = "\"" + escapeForPythonStringLiteral(variable) + "\""
    let expectedLiteral = "[" + expected.map { numericArrayLiteral($0) }.joined(separator: ", ") + "]"

    var assertKwargs: [String] = []
    if let rtol = check.rtol { assertKwargs.append("rtol=\(rtol)") }
    if let atol = check.atol { assertKwargs.append("atol=\(atol)") }
    let assertKwargsLine =
        assertKwargs.isEmpty
        ? ""
        : ",\n            " + assertKwargs.joined(separator: ",\n            ")

    return """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=numeric_array_close spec_hash=\(specHash) — edit the check, not this file.

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
func numericArrayLiteral(_ value: Double) -> String {
    if value.isNaN { return #"float("nan")"# }
    if value.isInfinite {
        return value > 0 ? #"float("inf")"# : #"float("-inf")"#
    }
    return "\(value)"
}

// MARK: - .figureCount

func defaultFigureCountLabel(_ check: NotebookCheck) -> String {
    let n = check.minFigures ?? 1
    return "Notebook produces ≥ \(n) figure\(n == 1 ? "" : "s")"
}

func renderFigureCount(_ check: NotebookCheck, specHash: String) -> String {
    let minFigures = check.minFigures ?? 1
    let label = check.name ?? defaultFigureCountLabel(check)

    return """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=figure_count spec_hash=\(specHash) — edit the check, not this file.

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

func defaultCellContainsLabel(_ check: NotebookCheck) -> String {
    let needle = check.containsText ?? ""
    let preview = needle.count > 30 ? String(needle.prefix(27)) + "..." : needle
    return "Notebook contains `\(preview)`"
}

func renderCellContains(_ check: NotebookCheck, specHash: String) -> String {
    let needle = check.containsText ?? ""
    let asRegex = check.regex ?? false
    let mustDiffer = check.mustDifferFrom
    let label = check.name ?? defaultCellContainsLabel(check)

    let needleLiteral = "\"" + escapeForPythonStringLiteral(needle) + "\""
    let mustDifferLiteral: String
    if let mustDiffer {
        mustDifferLiteral = "\"" + escapeForPythonStringLiteral(mustDiffer) + "\""
    } else {
        mustDifferLiteral = "None"
    }

    let matchExpr =
        asRegex
        ? "re.search(needle, src) is not None"
        : "needle in src"

    return """
        # Test: \(label)
        # Generated from notebook check "\(escapeForPythonStringLiteral(check.id))" kind=cell_contains spec_hash=\(specHash) — edit the check, not this file.

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

// APIServer/Utilities/PatternFamilyRenderer+StdoutEquality.swift
//
// `.stdoutEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - stdoutEquality

/// Renders a stdout-equality case.  The function is called inside a
/// `contextlib.redirect_stdout` block; the captured string is compared
/// to `case.expected` (a JSON string).  Single-trailing-newline
/// normalisation is applied to both sides so the natural `print("hi")`
/// shape (which emits `"hi\n"`) matches an instructor-typed Expected of
/// `"hi"`.  Internal newlines and leading whitespace are preserved.
/// The function's return value is intentionally discarded — instructors
/// who care about both stdout and the return value should write two
/// families.
func renderStdoutEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        import io as _io
        import contextlib as _contextlib

        \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected = \(c.expected.pythonLiteral)

        _buf = _io.StringIO()
        try:
            with _contextlib.redirect_stdout(_buf):
                student_module.\(family.functionName)(\(ctx.callArgs))
        except Exception as ex:
            # Same traceback-context trick as renderBoundaryEquality —
            # bare AssertionErrors get a `source:` line so the student
            # sees which line raised.
            import traceback as _tb
            _tb_frames = _tb.extract_tb(ex.__traceback__)
            _tb_src = ""
            if _tb_frames and _tb_frames[-1].line:
                _tb_src = f"\\n  source:   {_tb_frames[-1].line.strip()}"
            failed(
                "unexpected exception\\n"
                \(ctx.inputLineLiteral)
                f"  expected stdout: {expected!r}\\n"
                f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        # Trim a single trailing newline on both sides so `print("hi")`
        # (which emits "hi\\n") matches an instructor-typed Expected of "hi".
        # Internal newlines and leading whitespace are preserved.
        actual = _buf.getvalue()
        if actual.endswith("\\n"):
            actual = actual[:-1]
        expected_norm = expected
        if isinstance(expected_norm, str) and expected_norm.endswith("\\n"):
            expected_norm = expected_norm[:-1]

        if actual != expected_norm:
            failed(
                "wrong stdout\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected_norm!r}\\n"
                f"  got:      {actual!r}\\n"            )

        passed(f"Printed {actual!r}")
        """
}

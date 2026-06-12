// APIServer/Utilities/PatternFamilyRenderer+ApproximateEquality.swift
//
// `.approximateEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.
//
// Known quirk (documented, deliberate): this kind emits the variable
// declarations BEFORE the per-student preamble, while boundaryEquality
// emits the preamble first.  The bytes feed spec_hash / TestSetupCache
// keys — do not "fix" the ordering.

import Core

// MARK: - approximateEquality

/// Default tolerance when the family spec leaves `defaults.tolerance` nil.
/// 1e-6 matches Python's `math.isclose` default `abs_tol=0.0` / `rel_tol=1e-9`
/// in spirit but is permissive enough for typical student arithmetic.
private let defaultApproxTolerance: Double = 1e-6

/// Renders an approximate-equality case.  Shape mirrors
/// `renderBoundaryEquality` — same header, input echo, rich failure
/// messages — with the comparison replaced by
/// `abs(result - expected) > tolerance` guarded by an `isinstance` check
/// that rejects non-numeric returns cleanly.  The failure message
/// includes the tolerance and the actual delta so students see exactly
/// how far off they are.
func renderApproximateEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let ctx = callContext(for: family, case: c)

    let tolerance = family.defaults.tolerance ?? defaultApproxTolerance
    // Use JSONValue's Python rendering so whole-number tolerances come out
    // as floats (e.g. 1.0, not 1) — keeps the comparison well-typed.
    let toleranceLiteral = JSONValue.double(tolerance).pythonLiteral

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    // Per-student inputs (arg refs + the expected ref that resolve to a
    // global/section `=` expression) are bound at grading time from
    // `_ck_inputs.py` — identical mechanism to renderBoundaryEquality.  When the
    // case has no per-student refs this is "" and `expectedExpression` returns
    // the baked literal, so non-personalized cases render byte-for-byte as before.
    let preamble = personalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let preambleBlock = preamble.isEmpty ? "" : preamble + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(variableBlock)\(preambleBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected = \(expectedExpression(for: c))
        tolerance = \(toleranceLiteral)

        try:
            result = student_module.\(family.functionName)(\(ctx.callArgs))
        except Exception as ex:
            # v0.4.105: see renderBoundaryEquality — append source line for
            # traceback context (especially useful for bare AssertionError).
            import traceback as _tb
            _tb_frames = _tb.extract_tb(ex.__traceback__)
            _tb_src = ""
            if _tb_frames and _tb_frames[-1].line:
                _tb_src = f"\\n  source:   {_tb_frames[-1].line.strip()}"
            failed(
                "unexpected exception\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected!r} (±{tolerance})\\n"
                f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not isinstance(result, (int, float)) or isinstance(result, bool):
            failed(
                "wrong return type\\n"
                \(ctx.inputLineLiteral)
                f"  expected: a number close to {expected!r}\\n"
                f"  got:      {result!r} (type {type(result).__name__})\\n"            )

        delta = abs(result - expected)
        if delta > tolerance:
            failed(
                "value outside tolerance\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected!r} (±{tolerance})\\n"
                f"  got:      {result!r}\\n"
                f"  delta:    {delta}\\n"            )

        # v0.4.105: see renderBoundaryEquality — drop the input echo.
        passed(f"Returned {result!r} (within ±{tolerance})")
        """
}

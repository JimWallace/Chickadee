// APIServer/Utilities/PatternFamilyRenderer+UnorderedEquality.swift
//
// `.unorderedEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - unorderedEquality

/// Renders an order-insensitive list-equality case.  Same shape as
/// `renderBoundaryEquality` (header, per-student preamble, input echo, rich
/// failure messages, per-student `expected`) but the comparison canonicalises
/// each element (JSON with sorted keys, `str()` fallback) and compares the
/// sorted multisets, so a correct-but-reordered list still passes.
func renderUnorderedEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let ctx = callContext(for: family, case: c)

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    let preamble = personalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let preambleBlock = preamble.isEmpty ? "" : preamble + "\n\n"
    let expectedExpr = expectedExpression(for: c)

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(preambleBlock)\(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected = \(expectedExpr)

        # Order-insensitive comparison: canonicalise each element (JSON with
        # sorted keys, str() fallback for non-JSON values) and compare the
        # sorted multisets, so a correct-but-reordered result still passes.
        import json as _ck_json
        def _ck_canon(seq):
            return sorted(_ck_json.dumps(_e, sort_keys=True, default=str) for _e in seq)

        try:
            result = student_module.\(family.functionName)(\(ctx.callArgs))
        except Exception as ex:
            import traceback as _tb
            _tb_frames = _tb.extract_tb(ex.__traceback__)
            _tb_src = ""
            if _tb_frames and _tb_frames[-1].line:
                _tb_src = f"\\n  source:   {_tb_frames[-1].line.strip()}"
            failed(
                "unexpected exception\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not isinstance(result, list):
            failed(
                "wrong return type\\n"
                \(ctx.inputLineLiteral)
                f"  expected: a list (any order) like {expected!r}\\n"
                f"  got:      {result!r} (type {type(result).__name__})\\n"            )

        try:
            _ck_match = _ck_canon(result) == _ck_canon(expected)
        except Exception as ex:
            failed(
                "could not compare result\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"  got:      {result!r}\\n"
                f"  error:    {type(ex).__name__}: {ex}\\n"            )

        if not _ck_match:
            failed(
                "wrong elements (order doesn't matter)\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"  got:      {result!r}\\n"            )

        passed(f"Returned the expected {len(result)} element(s) (any order)")
        """
}

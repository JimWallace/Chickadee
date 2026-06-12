// APIServer/Utilities/PatternFamilyRenderer+BoundaryEquality.swift
//
// `.boundaryEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.
//
// Known quirk (documented, deliberate): this kind emits the per-student
// preamble BEFORE the variable declarations, while approximateEquality
// emits variables before the preamble.  Both orders are semantically
// equivalent in the generated Python, but the bytes feed spec_hash /
// TestSetupCache keys — do not "fix" the ordering.

import Core

// MARK: - boundaryEquality

func renderBoundaryEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let ctx = callContext(for: family, case: c)

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    // Per-student inputs (arg refs + the expected ref that resolve to a
    // global/section `=` expression) are bound at grading time from
    // `_ck_inputs.py`; see personalizationPreambleForCase.
    let preamble = personalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let preambleBlock = preamble.isEmpty ? "" : preamble + "\n\n"
    let expectedExpr = expectedExpression(for: c)

    // The `# Test:` line comes FIRST so test_runtime's _first_comment_label()
    // picks up the case label.  Provenance comes second — a reader opening
    // this file sees which family produced it, but the runtime label stays
    // student-readable.
    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(preambleBlock)\(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected = \(expectedExpr)

        try:
            result = student_module.\(family.functionName)(\(ctx.callArgs))
        except Exception as ex:
            # v0.4.105: bare AssertionError (`assert x == y` with no message)
            # used to render as just `error: AssertionError:` with no context.
            # Walk the traceback's last frame to pull the source line that
            # actually raised — this gives `error: AssertionError -- assert
            # name == record["name"]["given"]`, which tells the student
            # exactly which assertion failed.  Falls back silently when the
            # traceback can't be extracted.
            import traceback as _tb
            _tb_frames = _tb.extract_tb(ex.__traceback__)
            _tb_src = ""
            if _tb_frames and _tb_frames[-1].line:
                _tb_src = f"\\n  source:   {_tb_frames[-1].line.strip()}"
            failed(
                "unexpected exception\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected!r}\\n"
                f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if result != expected:
            failed(
                "wrong value\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected!r}\\n"
                f"  got:      {result!r}\\n"            )

        # v0.4.105: pass message no longer echoes the full input dict / list
        # (which can be hundreds of characters for HL7-shaped records).  The
        # row's case label already names the test ("Example", "Test 1", …);
        # the failure path still emits the full input alongside expected/got,
        # so we only lose redundant context.
        passed(f"Returned {result!r}")
        """
}

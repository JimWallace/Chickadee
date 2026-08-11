// APIServer/Utilities/PatternFamilyRenderer+UnorderedEquality.swift
//
// `.unorderedEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

// ORGANIZED BY KIND, NOT BY LANGUAGE. Every language's rendering of this kind
// lives in this file, so the six can be read against each other — which is the
// comparison the parity work keeps having to make and could not, when Python
// was sliced by kind and the other five were one file per language each
// re-switching on kind internally. Adding a tenth kind is one new file plus six
// dispatcher arms, and the dispatchers are exhaustive switches, so the compiler
// produces that worklist.
//
// The per-language files keep what is genuinely per-language: the kind
// dispatcher itself, the call-context builder, the case header, the
// personalization preamble and the identifier/comment helpers.

// THE ONE KIND THAT DOES NOT FIT CLEANLY, and it is worth knowing why. Only
// Python renders `unorderedEquality` with its own function. R, Lua, Octave, C++
// and Racket all render it through their `<lang>EqualityCase` with an
// `unordered: true` flag — ONE renderer serving two kinds — so those five live
// in PatternFamilyRenderer+BoundaryEquality.swift beside the ordered form they
// share code with. Splitting them to satisfy the file naming would have meant
// either duplicating a renderer or exporting half of one, which is a worse
// trade than a cross-reference.

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

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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
                _tb_src = f"\\n\(GeneratedMessage.source){_tb_frames[-1].line.strip()}"
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not isinstance(result, list):
            failed(
                "\(GeneratedMessage.wrongReturnType)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected)a list (any order) like {expected!r}\\n"
                f"\(GeneratedMessage.got){result!r} (type {type(result).__name__})\\n"            )

        try:
            _ck_match = _ck_canon(result) == _ck_canon(expected)
        except Exception as ex:
            failed(
                "could not compare result\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"\(GeneratedMessage.got){result!r}\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}\\n"            )

        if not _ck_match:
            failed(
                "\(GeneratedMessage.wrongElementsUnordered)\\n"
                \(ctx.inputLineLiteral)
                f"  expected (any order): {expected!r}\\n"
                f"\(GeneratedMessage.got){result!r}\\n"            )

        passed(f"Returned the expected {len(result)} element(s) (any order)")
        """
}

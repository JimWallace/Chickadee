// APIServer/Utilities/PatternFamilyRenderer+ReturnTypeCheck.swift
//
// `.returnTypeCheck` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - returnTypeCheck

func renderReturnTypeCheck(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    // expected is a JSON string naming the type (e.g. "DataFrame").
    let typeName: String = {
        if case .string(let s) = c.expected { return s }
        return "object"
    }()
    let typeNameLiteral = "\"" + escapeForPythonStringLiteral(typeName) + "\""
    // Type-name → check-expression mapping is shared with the notebook-check
    // `.variableExists` renderer (PythonScriptHelpers.swift).
    let typeCheckExpr = pythonTypeCheckExpression(typeName: typeName, valueExpr: "result")

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected_type_name = \(typeNameLiteral)

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
                f"\(GeneratedMessage.expected)a {expected_type_name} return value\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not (\(typeCheckExpr)):
            failed(
                "\(GeneratedMessage.wrongReturnType)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected_type_name}\\n"
                f"\(GeneratedMessage.got){type(result).__name__} (value: {result!r})\\n"            )

        passed(f"Returned a {type(result).__name__}")
        """
}

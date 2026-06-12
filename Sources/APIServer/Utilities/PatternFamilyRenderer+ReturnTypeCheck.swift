// APIServer/Utilities/PatternFamilyRenderer+ReturnTypeCheck.swift
//
// `.returnTypeCheck` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - returnTypeCheck

/// Maps the instructor-typed type name to a runtime check expression.
/// For Python builtins, `isinstance(result, <name>)` works directly.  For
/// pandas / numpy types, the renderer walks the result's class MRO so
/// the check works without forcing those imports at the top of the
/// generated test (matters for Pyodide grading where loadPackagesFromImports
/// drives package availability).
private func returnTypeCheckExpression(typeName: String) -> String {
    switch typeName {
    // Python builtins — straightforward isinstance.
    case "int": return "isinstance(result, int) and not isinstance(result, bool)"
    case "float": return "isinstance(result, float)"
    case "bool": return "isinstance(result, bool)"
    case "str": return "isinstance(result, str)"
    case "list": return "isinstance(result, list)"
    case "tuple": return "isinstance(result, tuple)"
    case "dict": return "isinstance(result, dict)"
    case "set": return "isinstance(result, set)"
    case "NoneType": return "result is None"
    // Library types — walk the MRO by class name so we don't have to
    // import the library to do the check.  Same trick as
    // `is_matplotlib_figure` in notebook_runtime.
    case "DataFrame":
        return #"any(getattr(b, "__name__", "") == "DataFrame" for b in type(result).__mro__)"#
    case "Series":
        return #"any(getattr(b, "__name__", "") == "Series" for b in type(result).__mro__)"#
    case "ndarray":
        return #"any(getattr(b, "__name__", "") == "ndarray" for b in type(result).__mro__)"#
    default:
        // Fallback: treat as a class name to MRO-walk.  Catches
        // student-defined classes referenced by name.
        return "any(getattr(b, \"__name__\", \"\") == \"\(typeName)\" for b in type(result).__mro__)"
    }
}

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
    let typeCheckExpr = returnTypeCheckExpression(typeName: typeName)

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
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
                _tb_src = f"\\n  source:   {_tb_frames[-1].line.strip()}"
            failed(
                "unexpected exception\\n"
                \(ctx.inputLineLiteral)
                f"  expected: a {expected_type_name} return value\\n"
                f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not (\(typeCheckExpr)):
            failed(
                "wrong return type\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected_type_name}\\n"
                f"  got:      {type(result).__name__} (value: {result!r})\\n"            )

        passed(f"Returned a {type(result).__name__}")
        """
}

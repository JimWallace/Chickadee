// APIServer/Utilities/PatternFamilyRenderer+ExceptionExpected.swift
//
// `.exceptionExpected` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - exceptionExpected

func renderExceptionExpected(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let exceptionName: String = {
        if case .string(let s) = c.expected { return s }
        return "Exception"
    }()
    let exceptionLiteral = "\"" + escapeForPythonStringLiteral(exceptionName) + "\""

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected_exception_name = \(exceptionLiteral)

        raised = None
        result = None
        try:
            result = student_module.\(family.functionName)(\(ctx.callArgs))
        except BaseException as ex:
            raised = ex

        if raised is None:
            failed(
                "expected exception was not raised\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected_exception_name}\\n"
                f"  got:      no exception (returned {result!r})\\n"            )

        # Match by class-name MRO walk so the test doesn't need to import
        # the user's exception class in this scope.  Any class in the
        # raised exception's __mro__ with __name__ == expected_exception_name
        # counts as a match — gives `ValueError` matching when the student
        # raises a subclass too.
        raised_chain = [getattr(b, "__name__", "") for b in type(raised).__mro__]
        if expected_exception_name not in raised_chain:
            failed(
                "wrong exception type\\n"
                \(ctx.inputLineLiteral)
                f"  expected: {expected_exception_name}\\n"
                f"  got:      {type(raised).__name__}: {raised}\\n"            )

        passed(f"Raised {type(raised).__name__} as expected")
        """
}

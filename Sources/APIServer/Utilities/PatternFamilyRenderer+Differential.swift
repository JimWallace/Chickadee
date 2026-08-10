// APIServer/Utilities/PatternFamilyRenderer+Differential.swift
//
// `.differential` renderer (Python). The kind that grades a submission against
// an instructor-written reference implementation instead of a tabulated
// expected value — see `PatternKind.differential` for what it is for and the
// two things to know before reaching for it.
//
// The reference source is rendered VERBATIM, at module scope, above the call.
// Not indented into a function body, not re-parsed, not translated: it is the
// instructor's own code in their own language, and anything else would make
// this kind a source-transformation tool. That is also why the call is
// `\(family.differentialReferenceName)(…)` rather than something derived from
// the source text — the renderer names what it will call and the validator
// makes the instructor define it.

import Core

func renderDifferential(
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
    let reference = family.referenceImplementation ?? ""

    // The reference is called FIRST, and a failure in it is reported as an
    // error in the test rather than as a student failure. A student cannot
    // make the reference raise except through the inputs the instructor chose,
    // so this outcome is the instructor's bug, and saying so is the difference
    // between "your function is wrong" and "this test is broken".
    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(preambleBlock)\(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)

        # Instructor's reference implementation, rendered verbatim.
        \(reference)

        try:
            expected = \(family.differentialReferenceName)(\(ctx.callArgs))
        except Exception as ex:
            errored(
                "\(GeneratedMessage.referenceFailed)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}\\n"            )

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
                f"\(GeneratedMessage.expected){expected!r}\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if result != expected:
            failed(
                "\(GeneratedMessage.wrongValue)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected!r}\\n"
                f"\(GeneratedMessage.got){result!r}\\n"            )

        passed(f"Returned {result!r}")
        """
}

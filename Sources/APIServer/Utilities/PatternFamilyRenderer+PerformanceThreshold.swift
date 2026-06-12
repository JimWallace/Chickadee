// APIServer/Utilities/PatternFamilyRenderer+PerformanceThreshold.swift
//
// `.performanceThreshold` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - performanceThreshold

func renderPerformanceThreshold(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let thresholdMs: Double = {
        switch c.expected {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return 1000.0
        }
    }()
    let thresholdLiteral = JSONValue.double(thresholdMs).pythonLiteral

    let variableDecls = combinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        import time as _time

        \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        threshold_ms = \(thresholdLiteral)

        _start = _time.perf_counter()
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
                f"  threshold: {threshold_ms} ms\\n"
                f"  error:     {type(ex).__name__}: {ex}" + _tb_src + "\\n"            )
        _elapsed_ms = (_time.perf_counter() - _start) * 1000.0

        if _elapsed_ms > threshold_ms:
            failed(
                "ran too slowly\\n"
                \(ctx.inputLineLiteral)
                f"  threshold: {threshold_ms} ms\\n"
                f"  elapsed:   {_elapsed_ms:.2f} ms\\n"            )

        passed(f"Completed in {_elapsed_ms:.2f} ms (threshold {threshold_ms} ms)")
        """
}

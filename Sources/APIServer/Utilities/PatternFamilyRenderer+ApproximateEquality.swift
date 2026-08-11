// APIServer/Utilities/PatternFamilyRenderer+ApproximateEquality.swift
//
// `.approximateEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.
//
// Known quirk (documented, deliberate): this kind emits the variable
// declarations BEFORE the per-student preamble, while boundaryEquality
// emits the preamble first.  The bytes feed spec_hash / TestSetupCache
// keys — do not "fix" the ordering.

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

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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
                _tb_src = f"\\n\(GeneratedMessage.source){_tb_frames[-1].line.strip()}"
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected!r} (±{tolerance})\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not isinstance(result, (int, float)) or isinstance(result, bool):
            failed(
                "\(GeneratedMessage.wrongReturnType)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected)a number close to {expected!r}\\n"
                f"\(GeneratedMessage.got){result!r} (type {type(result).__name__})\\n"            )

        delta = abs(result - expected)
        if delta > tolerance:
            failed(
                "\(GeneratedMessage.outsideTolerance)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected!r} (±{tolerance})\\n"
                f"\(GeneratedMessage.got){result!r}\\n"
                f"\(GeneratedMessage.delta){delta}\\n"            )

        # v0.4.105: see renderBoundaryEquality — drop the input echo.
        passed(f"Returned {result!r} (within ±{tolerance})")
        """
}

// MARK: - R

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
func rApproximateCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let ctx = rCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).rLiteral
    return """
        \(prelude)

        \(ctx.declBlock)expected  <- \(rExpectedExpression(for: c))
        tolerance <- \(tolerance)

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        result <- tryCatch(
            target(\(ctx.callArgs)),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee_format(expected), " (±", tolerance, ")\\n",
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        if (!is.numeric(result) || length(result) != 1L) {
            failed(paste0(
                "\(GeneratedMessage.wrongReturnType)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a single number close to ", chickadee_format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(result)))
        }

        delta <- abs(result - expected)
        if (delta > tolerance) {
            failed(paste0(
                "\(GeneratedMessage.outsideTolerance)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee_format(expected), " (±", tolerance, ")\\n",
                "\(GeneratedMessage.got)", chickadee_format(result), "\\n",
                "\(GeneratedMessage.delta)", chickadee_format(delta)))
        }

        passed(paste0("Returned ", chickadee_format(result), " (within ±", tolerance, ")"))
        """
}

// MARK: - Lua

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
func luaApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).luaLiteral
    return """
        \(prelude)

        \(ctx.declBlock)local expected = \(luaExpectedExpression(for: c))
        local tolerance = \(tolerance)

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), " (±", tostring(tolerance), ")\\n",
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if type(result) ~= "number" then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongReturnType)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a single number close to ", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(result),
            }))
        end

        local delta = math.abs(result - expected)
        if delta > tolerance then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.outsideTolerance)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), " (±", tostring(tolerance), ")\\n",
                "\(GeneratedMessage.got)", chickadee.format(result), "\\n",
                "\(GeneratedMessage.delta)", chickadee.format(delta),
            }))
        end

        chickadee.passed("\(GeneratedMessage.returned)" .. chickadee.format(result) .. " (within ±" .. tostring(tolerance) .. ")")
        """
}

// MARK: - Octave

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
func octaveApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).octaveLiteral
    return """
        \(prelude)

        \(ctx.declBlock)expected = \(octaveExpectedExpression(for: c));
        tolerance = \(tolerance);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) " (±" num2str(tolerance) ")\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !isnumeric(result) || !isscalar(result)
            chickadee.failed(["\(GeneratedMessage.wrongReturnType)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a single number close to " chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end

        delta = abs(result - expected);
        if delta > tolerance
            chickadee.failed(["\(GeneratedMessage.outsideTolerance)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) " (±" num2str(tolerance) ")\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result) "\\n" ...
                "\(GeneratedMessage.delta)" chickadee.format(delta)]);
        end

        chickadee.passed(["Returned " chickadee.format(result) " (within ±" num2str(tolerance) ")"]);
        """
}

// MARK: - C++

func cppApproximateBody(
    target: String, context: CppCallContext, c: PatternCase, family: PatternFamily
) -> String {
    let tolerance = family.defaults.tolerance ?? 1e-6
    return cppGuarded(
        """
        auto expected = \(context.expectedExpression);
        auto result = \(target)(\(context.callArgs));
        if (!ck::close(result, expected, \(tolerance))) {
            ck::failed(std::string("\(GeneratedMessage.outsideTolerance)\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)" + ck::format(expected) + " (±\(tolerance))\\n"
                + "\(GeneratedMessage.got)" + ck::format(result));
        }
        ck::passed("\(GeneratedMessage.returned)" + ck::format(result) + " (within ±\(tolerance))");
        """, inputLine: context.inputLine)
}

// MARK: - Racket

func racketApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).racketLiteral
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        (define tolerance \(tolerance))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (unless (and (real? actual) (real? expected))
          (chickadee-failed (string-append                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                             \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        (define delta (abs (- actual expected)))
        (if (<= delta tolerance)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual) "\\n"
                               \(JSONValue.string(GeneratedMessage.delta).racketLiteral) (chickadee-format delta))))
        """ + "\n"
}

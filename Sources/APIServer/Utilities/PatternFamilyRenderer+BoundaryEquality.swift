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

// CARRIES `unorderedEquality` TOO, for every language but Python: those five
// render both kinds through one `<lang>EqualityCase` with an `unordered:` flag,
// so the two kinds share a file rather than a renderer being split across two.
// Python's own unordered renderer is in PatternFamilyRenderer+UnorderedEquality.swift.

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

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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

        # v0.4.105: pass message no longer echoes the full input dict / list
        # (which can be hundreds of characters for HL7-shaped records).  The
        # row's case label already names the test ("Example", "Test 1", …);
        # the failure path still emits the full input alongside expected/got,
        # so we only lose redundant context.
        passed(f"Returned {result!r}")
        """
}

// MARK: - R

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
func rEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = rCallContext(for: family, case: c)
    let comparator = unordered ? "chickadee_unordered_equal" : "chickadee_equal"
    let mismatchLabel = unordered ? "\(GeneratedMessage.wrongElements)" : "\(GeneratedMessage.wrongValue)"
    let expectedLabel = unordered ? "the same elements as" : ""
    let expectedLine =
        expectedLabel.isEmpty
        ? #""\#(GeneratedMessage.expected)", chickadee_format(expected), "\n","#
        : #""\#(GeneratedMessage.expected)\#(expectedLabel) ", chickadee_format(expected), "\n","#
    return """
        \(prelude)

        \(ctx.declBlock)expected <- \(rExpectedExpression(for: c))

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        result <- tryCatch(
            target(\(ctx.callArgs)),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                \(expectedLine)
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        if (!\(comparator)(result, expected)) {
            failed(paste0(
                "\(mismatchLabel)\\n",
                \(ctx.inputLine)
                \(expectedLine)
                "\(GeneratedMessage.got)", chickadee_format(result)))
        }

        passed(paste0("Returned ", chickadee_format(result)))
        """
}

// MARK: - Lua

func luaEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let comparator = unordered ? "chickadee.unordered_equal" : "chickadee.equal"
    let mismatchLabel = unordered ? GeneratedMessage.wrongElements : GeneratedMessage.wrongValue
    let expectedLine =
        unordered
        ? "\"\(GeneratedMessage.expected)the same elements as \", chickadee.format(expected), \"\\n\","
        : "\"\(GeneratedMessage.expected)\", chickadee.format(expected), \"\\n\","
    return """
        \(prelude)

        \(ctx.declBlock)local expected = \(luaExpectedExpression(for: c))

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                \(expectedLine)
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if not \(comparator)(result, expected) then
            chickadee.failed(table.concat({
                "\(mismatchLabel)\\n",
                \(ctx.inputLine)
                \(expectedLine)
                "\(GeneratedMessage.got)", chickadee.format(result),
            }))
        end

        chickadee.passed("\(GeneratedMessage.returned)" .. chickadee.format(result))
        """
}

// MARK: - Octave

func octaveEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let comparator = unordered ? "chickadee.unordered_equal" : "chickadee.equal"
    let mismatchLabel = unordered ? GeneratedMessage.wrongElements : GeneratedMessage.wrongValue
    let expectedLabel = unordered ? "the same elements as " : ""
    return """
        \(prelude)

        \(ctx.declBlock)expected = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)\(expectedLabel)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !\(comparator)(result, expected)
            chickadee.failed(["\(mismatchLabel)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)\(expectedLabel)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end

        chickadee.passed(["Returned " chickadee.format(result)]);
        """
}

// MARK: - C++

func cppEqualityBody(
    target: String, context: CppCallContext, c: PatternCase, unordered: Bool
) -> String {
    let compare = unordered ? "ck::unordered_equal" : "ck::equal"
    let mismatch = unordered ? GeneratedMessage.wrongElements : GeneratedMessage.wrongValue
    return cppGuarded(
        """
        auto expected = \(context.expectedExpression);
        auto result = \(target)(\(context.callArgs));
        if (!\(compare)(result, expected)) {
            ck::failed(std::string("\(mismatch)\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)" + ck::format(expected) + "\\n"
                + "\(GeneratedMessage.got)" + ck::format(result));
        }
        ck::passed("\(GeneratedMessage.returned)" + ck::format(result));
        """, inputLine: context.inputLine)
}

// MARK: - Racket

func racketEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let compare = unordered ? "chickadee-unordered-equal?" : "chickadee-equal?"
    // Python names "wrong value" for boundaryEquality and not for
    // unorderedEquality; the conformance matrix pins that a kind uses the same
    // vocabulary in every language, so the difference is carried here rather
    // than invented.
    let mismatchPrefix =
        unordered ? "" : JSONValue.string(GeneratedMessage.wrongValue).racketLiteral + " \"\\n\""
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (if (\(compare) actual expected)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append \(mismatchPrefix)
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

// MARK: - Java

func javaEqualityBody(
    target: String, context: JavaCallContext, c: PatternCase, unordered: Bool
) -> String {
    let compare = unordered ? "ck.unorderedEqual" : "ck.equal"
    let mismatch = unordered ? GeneratedMessage.wrongElements : GeneratedMessage.wrongValue
    return javaGuarded(
        """
        var expected = \(context.expectedExpression);
        var result = \(target)(\(context.callArgs));
        if (!\(compare)(result, expected)) {
            ck.failed("\(mismatch)\\n"
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)" + ck.format(expected) + "\\n"
                + "\(GeneratedMessage.got)" + ck.format(result));
        }
        ck.passed("\(GeneratedMessage.returned)" + ck.format(result));
        """, inputLine: context.inputLine)
}

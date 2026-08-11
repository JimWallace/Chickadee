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

// MARK: - R

/// `.differential` — compares the student's function against the instructor's
/// reference implementation, which is rendered verbatim above the call.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose, so the outcome is a
/// broken test and telling the student their function is wrong would send them
/// to debug the wrong code.
func rDifferentialCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = rCallContext(for: family, case: c)
    let reference = family.referenceImplementation ?? ""
    return """
        \(prelude)

        \(ctx.declBlock)
        # Instructor's reference implementation, rendered verbatim.
        \(reference)

        expected <- tryCatch(
            \(family.differentialReferenceName)(\(ctx.callArgs)),
            error = function(e) errored(paste0(
                "\(GeneratedMessage.referenceFailed)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        result <- tryCatch(
            target(\(ctx.callArgs)),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee_format(expected), "\\n",
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        if (!chickadee_equal(result, expected)) {
            failed(paste0(
                "\(GeneratedMessage.wrongValue)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee_format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(result)))
        }

        passed(paste0("Returned ", chickadee_format(result)))
        """
}

// MARK: - Lua

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
/// `.differential` — compares the student's function against the instructor's
/// reference implementation, rendered verbatim above the call.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose, so the outcome is a
/// broken test and telling the student their function is wrong would send them
/// to debug the wrong code.
func luaDifferentialCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let reference = family.referenceImplementation ?? ""
    return """
        \(prelude)

        \(ctx.declBlock)
        -- Instructor's reference implementation, rendered verbatim.
        \(reference)

        local ref_ok, expected = pcall(\(family.differentialReferenceName)\(ctx.callArgsSuffix))
        if not ref_ok then
            chickadee.errored(table.concat({
                "\(GeneratedMessage.referenceFailed)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", tostring(expected),
            }))
        end

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if not chickadee.equal(result, expected) then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongValue)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(result),
            }))
        end

        chickadee.passed("\(GeneratedMessage.returned)" .. chickadee.format(result))
        """
}

// MARK: - Octave

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
/// `.differential` — compares the student's function against the instructor's
/// reference implementation, rendered verbatim above the call.
///
/// The reference is a `function … end` block in a generated `.m` file, which is
/// legal because the header's `chickadee = test_runtime();` already made the
/// file a SCRIPT. A generated test that opened with the reference would be read
/// as a function file and nothing in it would run — the same rule the eval
/// worker's `1;` boot guard exists for.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose, so the outcome is a
/// broken test and telling the student their function is wrong would send them
/// to debug the wrong code.
func octaveDifferentialCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let reference = family.referenceImplementation ?? ""
    return """
        \(prelude)

        \(ctx.declBlock)
        % Instructor's reference implementation, rendered verbatim.
        \(reference)

        try
            expected = \(family.differentialReferenceName)(\(ctx.callArgs));
        catch err
            chickadee.errored(["\(GeneratedMessage.referenceFailed)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.error)" err.message]);
        end

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !chickadee.equal(result, expected)
            chickadee.failed(["\(GeneratedMessage.wrongValue)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end

        chickadee.passed(["Returned " chickadee.format(result)]);
        """
}

// MARK: - C++

/// `.differential` — compares the student's function against the instructor's
/// reference. See `PatternKind.differential`.
///
/// C++ differs from the interpreted languages in one way worth knowing: the
/// reference is COMPILED with the test, so a reference that does not compile is
/// a build failure — the collection's `buildStatus` fails and no case runs at
/// all — rather than a per-case `errored`. That is louder, and it lands on the
/// instructor at validation, which is where a broken reference should land.
///
/// A reference that compiles but THROWS gets its own try/catch rather than
/// riding the shared guard. Under the shared one it would report as
/// "unexpected exception", which is the student-failure message: the same
/// misattribution the other five languages avoid by reporting `errored`.
func cppDifferentialBody(
    family: PatternFamily, context: CppCallContext, c: PatternCase
) -> String {
    cppGuarded(
        """
        \(cppDifferentialExpected(family: family, context: context))
        auto result = \(family.functionName)(\(context.callArgs));
        if (!ck::equal(result, expected)) {
            ck::failed(std::string("\(GeneratedMessage.wrongValue)\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)" + ck::format(expected) + "\\n"
                + "\(GeneratedMessage.got)" + ck::format(result));
        }
        ck::passed("\(GeneratedMessage.returned)" + ck::format(result));
        """, inputLine: context.inputLine)
}

// MARK: - Racket

/// `.differential` — compares the student's function against the instructor's
/// reference implementation, spliced verbatim into the generated module.
///
/// The reference is called with `apply`, because the call context hands its
/// arguments over as a list — the same list `chickadee-call` takes to reach
/// into the student's namespace. The student's function still goes through
/// `chickadee-call`: it lives in a separately-loaded module, and this one does
/// not.
///
/// The instructor's source is spliced into a `#lang racket/base` module, so it
/// must be definitions only — a `#lang` line of its own would not parse there.
/// That is stated in the kind's documentation rather than validated, because
/// deciding what is "a definition" needs a Racket reader.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose.
func racketDifferentialCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let reference = family.referenceImplementation ?? ""
    return """
        \(prelude)

        \(ctx.declBlock)

        ; Instructor's reference implementation, rendered verbatim.
        \(reference)

        (define expected
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-errored (string-append \(JSONValue.string(GeneratedMessage.referenceFailed).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (apply \(family.differentialReferenceName) \(ctx.argList))))

        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (if (chickadee-equal? actual expected)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.wrongValue).racketLiteral) "\\n"
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

// APIServer/Utilities/PatternFamilyRenderer+ExceptionExpected.swift
//
// `.exceptionExpected` renderer.  Split from PatternFamilyRenderer.swift
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

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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
                f"\(GeneratedMessage.expected){expected_exception_name}\\n"
                f"\(GeneratedMessage.got)no exception (returned {result!r})\\n"            )

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
                f"\(GeneratedMessage.expected){expected_exception_name}\\n"
                f"\(GeneratedMessage.got){type(raised).__name__}: {raised}\\n"            )

        passed(f"Raised {type(raised).__name__} as expected")
        """
}

// MARK: - R

/// `.exceptionExpected` — the call must raise. R has no exception class
/// hierarchy like Python's, so `expected` is matched against the condition's
/// class vector *or* its message (case-insensitive substring), which covers
/// both `stop("...")` and custom condition classes.
func rExceptionCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let ctx = rCallContext(for: family, case: c)
    let expectedName: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    let matchBlock =
        expectedName.isEmpty
        ? ""
        : """


            wanted <- \(JSONValue.string(expectedName).rLiteral)
            classes <- paste(class(err), collapse = ", ")
            hit <- any(grepl(wanted, class(err), fixed = TRUE)) ||
                grepl(tolower(wanted), tolower(conditionMessage(err)), fixed = TRUE)
            if (!hit) {
                failed(paste0(
                    "wrong error raised\\n",
                    \(ctx.inputLine)
                    "\(GeneratedMessage.expected)an error matching ", wanted, "\\n",
                    "\(GeneratedMessage.got)", classes, ": ", conditionMessage(err)))
            }
        """
    return """
        \(prelude)

        \(ctx.declBlock)student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        err <- NULL
        result <- withCallingHandlers(
            tryCatch(target(\(ctx.callArgs)), error = function(e) { err <<- e; NULL }),
            warning = function(w) invokeRestart("muffleWarning")
        )

        if (is.null(err)) {
            failed(paste0(
                "expected an error, but the call succeeded\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.got)", chickadee_format(result)))
        }\(matchBlock)

        passed(paste0("Raised ", class(err)[[1L]], " as expected"))
        """
}

// MARK: - Lua

/// `.exceptionExpected` — the call must raise.
///
/// Lua has no exception hierarchy and no exception TYPE: `error("boom")` raises
/// a string, `error({code = 1})` raises a table, and neither carries a class. So
/// `expected` is matched case-insensitively against the rendered error value,
/// which is the only thing every raise has in common. R matches against the
/// condition's class vector OR its message for the same reason; Python, which
/// does have a hierarchy, walks the MRO instead.
func luaExceptionCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let expectedName: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    let matchBlock =
        expectedName.isEmpty
        ? ""
        : """


            local wanted = \(JSONValue.string(expectedName).luaLiteral)
            local raised_text = tostring(err)
            if not string.find(string.lower(raised_text), string.lower(wanted), 1, true) then
                chickadee.failed(table.concat({
                    "wrong error raised\\n",
                    \(ctx.inputLine)
                    "\(GeneratedMessage.expected)an error matching ", wanted, "\\n",
                    "\(GeneratedMessage.got)", raised_text,
                }))
            end
        """
    return """
        \(prelude)

        \(ctx.declBlock)local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, err = pcall(target\(ctx.callArgsSuffix))

        if ok then
            chickadee.failed(table.concat({
                "expected an error, but the call succeeded\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.got)", chickadee.format(err),
            }))
        end\(matchBlock)

        chickadee.passed("Raised an error as expected")
        """
}

// MARK: - Octave

/// `.exceptionExpected` — the call must raise. Octave errors carry an
/// `identifier` (e.g. "Octave:undefined-function") and a `message`; `expected`
/// is matched case-insensitively as a substring of either, which covers both
/// `error("id:sub", ...)` styles and plain-message errors.
func octaveExceptionCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let expectedName: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    let matchBlock =
        expectedName.isEmpty
        ? ""
        : """


            wanted = \(JSONValue.string(expectedName).octaveLiteral);
            hit = !isempty(strfind(lower(caught.identifier), lower(wanted))) ...
                || !isempty(strfind(lower(caught.message), lower(wanted)));
            if !hit
                chickadee.failed(["wrong error raised\\n" ...
                    \(ctx.inputLine)
                    "\(GeneratedMessage.expected)an error matching " wanted "\\n" ...
                    "\(GeneratedMessage.got)" caught.identifier ": " caught.message]);
            end
        """
    return """
        \(prelude)

        \(ctx.declBlock)student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        caught = [];
        try
            result = target(\(ctx.callArgs));
        catch err
            caught = err;
        end

        if isempty(caught)
            chickadee.failed(["expected an error, but the call succeeded\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.got)" chickadee.format(result)]);
        end\(matchBlock)

        chickadee.passed(["Raised an error as expected (" caught.message ")"]);
        """
}

// MARK: - C++

func cppExceptionBody(
    target: String, context: CppCallContext, c: PatternCase
) -> String {
    let substring: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    return """
        std::string what;
        auto outcome = ck::expect_throw(
            [&] { (void)\(target)(\(context.callArgs)); }, "\(substring)", what);
        if (outcome == ck::ThrowOutcome::returned) {
            ck::failed(std::string("no error raised\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)an exception\(substring.isEmpty ? "" : " matching \\\"\(substring)\\\"")");
        }
        if (outcome == ck::ThrowOutcome::threwOther) {
            ck::failed(std::string("wrong error raised\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)an exception matching \\"\(substring)\\"\\n"
                + "\(GeneratedMessage.got)" + what);
        }
        ck::passed("Raised as expected: " + what);
        """
}

// MARK: - Racket

/// Racket has no exception TYPES in the Python sense that a student would name,
/// so the expectation is matched against the message — the same posture the Lua
/// renderer takes for the same reason.
func racketExceptionCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let expectedText: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected-error \(JSONValue.string(expectedText).racketLiteral))
        \(racketLoadAndGuard(family))

        (define outcome
          (with-handlers ([exn:fail? (lambda (e) (cons 'raised (exn-message e)))])
            (cons 'returned (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList)))))

        (cond
          [(eq? (car outcome) 'returned)
           (chickadee-failed (string-append "expected an error\\n"
                              \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-error "\\n"
                              \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format (cdr outcome))))]
          [(or (string=? expected-error "")
               (regexp-match? (regexp (regexp-quote expected-error)) (cdr outcome)))
           (chickadee-passed "Raised the expected error")]
          [else
           (chickadee-failed (string-append                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-error "\\n"
                              \(JSONValue.string(GeneratedMessage.error).racketLiteral) (cdr outcome)))])
        """ + "\n"
}

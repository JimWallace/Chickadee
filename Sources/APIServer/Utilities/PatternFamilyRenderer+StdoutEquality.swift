// APIServer/Utilities/PatternFamilyRenderer+StdoutEquality.swift
//
// `.stdoutEquality` renderer.  Split from PatternFamilyRenderer.swift
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

// MARK: - stdoutEquality

/// Renders a stdout-equality case.  The function is called inside a
/// `contextlib.redirect_stdout` block; the captured string is compared
/// to `case.expected` (a JSON string).  Single-trailing-newline
/// normalisation is applied to both sides so the natural `print("hi")`
/// shape (which emits `"hi\n"`) matches an instructor-typed Expected of
/// `"hi"`.  Internal newlines and leading whitespace are preserved.
/// The function's return value is intentionally discarded — instructors
/// who care about both stdout and the return value should write two
/// families.
func renderStdoutEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let ctx = callContext(for: family, case: c)

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        import io as _io
        import contextlib as _contextlib

        \(variableBlock)\(ctx.declLines.isEmpty ? "# (no input arguments)" : ctx.declLines)
        expected = \(c.expected.pythonLiteral)

        _buf = _io.StringIO()
        try:
            with _contextlib.redirect_stdout(_buf):
                student_module.\(family.functionName)(\(ctx.callArgs))
        except Exception as ex:
            # Same traceback-context trick as renderBoundaryEquality —
            # bare AssertionErrors get a `source:` line so the student
            # sees which line raised.
            import traceback as _tb
            _tb_frames = _tb.extract_tb(ex.__traceback__)
            _tb_src = ""
            if _tb_frames and _tb_frames[-1].line:
                _tb_src = f"\\n\(GeneratedMessage.source){_tb_frames[-1].line.strip()}"
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                \(ctx.inputLineLiteral)
                f"  expected stdout: {expected!r}\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        # Trim a single trailing newline on both sides so `print("hi")`
        # (which emits "hi\\n") matches an instructor-typed Expected of "hi".
        # Internal newlines and leading whitespace are preserved.
        actual = _buf.getvalue()
        if actual.endswith("\\n"):
            actual = actual[:-1]
        expected_norm = expected
        if isinstance(expected_norm, str) and expected_norm.endswith("\\n"):
            expected_norm = expected_norm[:-1]

        if actual != expected_norm:
            failed(
                "wrong stdout\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected_norm!r}\\n"
                f"\(GeneratedMessage.got){actual!r}\\n"            )

        passed(f"Printed {actual!r}")
        """
}

// MARK: - R

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
func rStdoutCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let ctx = rCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)expected_output <- \(rExpectedExpression(for: c))

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        .ck_normalize <- function(text) {
            lines <- strsplit(as.character(text), "\\n", fixed = TRUE)[[1L]]
            lines <- sub("[[:space:]]+$", "", lines)
            while (length(lines) > 0L && !nzchar(lines[[length(lines)]])) {
                lines <- lines[-length(lines)]
            }
            paste(lines, collapse = "\\n")
        }

        captured <- tryCatch(
            paste(capture.output(target(\(ctx.callArgs))), collapse = "\\n"),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        if (!identical(.ck_normalize(captured), .ck_normalize(expected_output))) {
            failed(paste0(
                "\(GeneratedMessage.wrongOutput)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee_format(.ck_normalize(expected_output)), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(.ck_normalize(captured))))
        }

        passed("Printed the expected output")
        """
}

// MARK: - Lua

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
///
/// Lua has no `capture.output`, so `print` and `io` are swapped for collectors
/// around the call and restored afterwards. They are swapped in the STUDENT's
/// environment table, not in `_G`: the submission is loaded with `__index = _G`,
/// so an assignment into its own table shadows the global for the student's code
/// while leaving the harness's own `print` untouched — which matters because
/// `chickadee.failed` writes the result JSON with `io.write`.
///
/// The `io` proxy captures every ordinary way a student prints: `print`,
/// `io.write(...)`, `io.stdout:write(...)`, and chained `io.write(a):write(b)` —
/// the proxy's `write` drops a leading self argument (so the method form works)
/// and returns the handle (so chaining works), and `io.stdout` is the same
/// handle. Earlier this swapped only a bare `io.write`, so `io.stdout:write` and
/// chained writes escaped capture and a CORRECT submission failed with empty
/// output. The one path still uncapturable is a student who binds
/// `local print = print` (or `local w = io.write`) *before* the call: that is an
/// upvalue frozen at load time, which per-call swapping cannot reach. This kind
/// grades output produced through `print` / `io.write` / `io.stdout`, which is
/// what an assignment using it should ask for.
func luaStdoutCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)local expected_output = \(luaExpectedExpression(for: c))

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local function ck_normalize(text)
            local lines = {}
            for line in (tostring(text) .. "\\n"):gmatch("([^\\n]*)\\n") do
                lines[#lines + 1] = (line:gsub("%s+$", ""))
            end
            while #lines > 0 and lines[#lines] == "" do
                table.remove(lines)
            end
            return table.concat(lines, "\\n")
        end

        local captured = {}
        student.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            captured[#captured + 1] = table.concat(parts, "\\t") .. "\\n"
        end

        -- A stand-in handle used for both `io` and `io.stdout`, so print,
        -- io.write, io.stdout:write and chained io.write(a):write(b) are all
        -- captured. `write` drops a leading self argument (the method forms) and
        -- returns the handle (so chaining works).
        local ck_stdout = {}
        function ck_stdout.write(...)
            local n = select("#", ...)
            local start = (n >= 1 and select(1, ...) == ck_stdout) and 2 or 1
            for i = start, n do
                captured[#captured + 1] = tostring((select(i, ...)))
            end
            return ck_stdout
        end
        student.io = setmetatable(
            { write = ck_stdout.write, stdout = ck_stdout },
            { __index = io })

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        student.print = nil
        student.io = nil

        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        local actual_output = table.concat(captured)
        if ck_normalize(actual_output) ~= ck_normalize(expected_output) then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongOutput)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(ck_normalize(expected_output)), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(ck_normalize(actual_output)),
            }))
        end

        chickadee.passed("Printed the expected output")
        """
}

// MARK: - Octave

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
///
/// Captured with `evalc`, which intercepts the interpreter's own output stream
/// — `printf`, `disp` and `fprintf(1, …)` alike — so unlike Lua's shadowed
/// `print` there is no idiomatic student spelling that escapes it. The
/// evaluated call ends in `;` so a non-suppressed return value cannot leak an
/// `ans = …` echo into the comparison.
func octaveStdoutCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)expected_output = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        function out = ck_normalize(text)
            lines = strsplit(text, sprintf("\\n"), "CollapseDelimiters", false);
            for i = 1:numel(lines)
                lines{i} = regexprep(lines{i}, '\\s+$', "");
            end
            while !isempty(lines) && isempty(lines{end})
                lines(end) = [];
            end
            out = strjoin(lines, sprintf("\\n"));
        end

        try
            captured = evalc("target(\(octaveEvalcArgs(ctx.callArgs)));");
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.error)" err.message]);
        end

        if !strcmp(ck_normalize(captured), ck_normalize(expected_output))
            chickadee.failed(["\(GeneratedMessage.wrongOutput)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" chickadee.format(ck_normalize(expected_output)) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(ck_normalize(captured))]);
        end

        chickadee.passed("Printed the expected output");
        """
}

// MARK: - C++

func cppStdoutBody(
    target: String, context: CppCallContext, c: PatternCase
) -> String {
    cppGuarded(
        """
        auto expected = \(context.expectedExpression);
        ck::CaptureStdout ck_capture;
        (void)\(target)(\(context.callArgs));
        auto ck_printed = ck_capture.finish();
        // Trailing-newline tolerance, matching the other stdout renderers.
        while (!ck_printed.empty() && (ck_printed.back() == '\\n' || ck_printed.back() == '\\r')) {
            ck_printed.pop_back();
        }
        std::string ck_wanted(expected);
        while (!ck_wanted.empty() && (ck_wanted.back() == '\\n' || ck_wanted.back() == '\\r')) {
            ck_wanted.pop_back();
        }
        if (ck_printed != ck_wanted) {
            ck::failed(std::string("\(GeneratedMessage.wrongOutput)\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)" + ck::format(ck_wanted) + "\\n"
                + "\(GeneratedMessage.got)" + ck::format(ck_printed));
        }
        ck::passed("Printed the expected output");
        """, inputLine: context.inputLine)
}

// MARK: - Racket

func racketStdoutCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        \(racketLoadAndGuard(family))

        (define printed
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (let-values ([(out _) (chickadee-call/capture ns '\(racketArgumentName(family.functionName)) \(ctx.argList))])
              out)))

        (if (chickadee-stdout-matches? printed expected)
            (chickadee-passed "Printed the expected output")
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format printed))))
        """ + "\n"
}

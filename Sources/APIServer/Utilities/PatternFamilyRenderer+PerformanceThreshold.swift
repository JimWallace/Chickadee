// APIServer/Utilities/PatternFamilyRenderer+PerformanceThreshold.swift
//
// `.performanceThreshold` renderer.  Split from PatternFamilyRenderer.swift
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

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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
                _tb_src = f"\\n\(GeneratedMessage.source){_tb_frames[-1].line.strip()}"
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.threshold){threshold_ms} ms\\n"
                f"\(GeneratedMessage.performanceError){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )
        _elapsed_ms = (_time.perf_counter() - _start) * 1000.0

        if _elapsed_ms > threshold_ms:
            failed(
                "ran too slowly\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.threshold){threshold_ms} ms\\n"
                f"\(GeneratedMessage.elapsed){_elapsed_ms:.2f} ms\\n"            )

        passed(f"Completed in {_elapsed_ms:.2f} ms (threshold {threshold_ms} ms)")
        """
}

// MARK: - R

/// `.performanceThreshold` — the call must finish inside a millisecond budget.
func rPerformanceCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let ctx = rCallContext(for: family, case: c)
    let budget: String = {
        switch c.expected {
        case .int(let i): return JSONValue.double(Double(i)).rLiteral
        case .double(let d): return JSONValue.double(d).rLiteral
        default: return "1000"
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)budget_ms <- \(budget)

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        started <- Sys.time()
        result <- tryCatch(
            target(\(ctx.callArgs)),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )
        elapsed_ms <- as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000

        if (elapsed_ms > budget_ms) {
            failed(paste0(
                "too slow\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.budget)", budget_ms, " ms\\n",
                "\(GeneratedMessage.took)", round(elapsed_ms, 1), " ms\\n",
                "  Hint: look for repeated work that could be done once."))
        }

        passed(paste0("Completed in ", round(elapsed_ms, 1), " ms (budget ", budget_ms, " ms)"))
        """
}

// MARK: - Lua

/// `.performanceThreshold` — the call must finish inside a millisecond budget.
///
/// `os.clock()` measures CPU time, not wall clock, which is the more stable
/// signal for "did the student write an accidentally quadratic loop" and is the
/// only portable timer in Lua's standard library (`os.time()` has one-second
/// resolution and is useless here).
///
/// Fields are labelled `budget:` / `took:` on the standard column, matching R.
/// Python's copy of this kind says `threshold:` / `elapsed:` on a wider one —
/// a divergence that predates Lua and is documented in `GeneratedMessage`.
func luaPerformanceCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let budget: String = {
        switch c.expected {
        case .int(let i): return JSONValue.double(Double(i)).luaLiteral
        case .double(let d): return JSONValue.double(d).luaLiteral
        default: return "1000.0"
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)local budget_ms = \(budget)

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local started = os.clock()
        local ok, result = pcall(target\(ctx.callArgsSuffix))
        local elapsed_ms = (os.clock() - started) * 1000.0

        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if elapsed_ms > budget_ms then
            chickadee.failed(table.concat({
                "too slow\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.budget)", string.format("%.1f", budget_ms), " ms\\n",
                "\(GeneratedMessage.took)", string.format("%.1f", elapsed_ms), " ms\\n",
                "  Hint: look for repeated work that could be done once.",
            }))
        end

        chickadee.passed("Completed in " .. string.format("%.1f", elapsed_ms)
            .. " ms (budget " .. string.format("%.1f", budget_ms) .. " ms)")
        """
}

// MARK: - Octave

/// `.performanceThreshold` — the call must finish inside a millisecond budget.
func octavePerformanceCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let budget: String = {
        switch c.expected {
        case .int(let i): return JSONValue.double(Double(i)).octaveLiteral
        case .double(let d): return JSONValue.double(d).octaveLiteral
        default: return "1000"
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)budget_ms = \(budget);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        started = tic();
        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.error)" err.message]);
        end
        elapsed_ms = toc(started) * 1000;

        if elapsed_ms > budget_ms
            chickadee.failed(["too slow\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.budget)" num2str(budget_ms) " ms\\n" ...
                "\(GeneratedMessage.took)" num2str(round(elapsed_ms * 10) / 10) " ms\\n" ...
                "  Hint: look for repeated work that could be done once."]);
        end

        chickadee.passed(["Completed in " num2str(round(elapsed_ms * 10) / 10) ...
            " ms (budget " num2str(budget_ms) " ms)"]);
        """
}

// MARK: - C++

func cppPerformanceBody(
    target: String, context: CppCallContext, c: PatternCase
) -> String {
    // The budget is authored in MILLISECONDS, like every other renderer.
    let budgetMs: String = {
        switch c.expected {
        case .int(let i): return String(Double(i))
        case .double(let d): return String(d)
        default: return "1000.0"
        }
    }()
    // The call is a bare statement rather than a bound result, for the reason
    // the Java arm already states: a timed function may well be void, and
    // `auto result = f(x)` on a void call is
    // `error: deduced type 'void' for 'result' is incomplete` — which fails
    // every case in the family while the 0-point existence guard (which only
    // takes the function's address) still passes, so nothing points at it.
    return cppGuarded(
        """
        auto ck_started = std::chrono::steady_clock::now();
        \(target)(\(context.callArgs));
        double ck_elapsed_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - ck_started).count();
        if (ck_elapsed_ms > \(budgetMs)) {
            ck::failed(std::string("too slow\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.threshold)" + ck::format(\(budgetMs)) + " ms\\n"
                + "\(GeneratedMessage.elapsed)" + ck::format(ck_elapsed_ms) + " ms");
        }
        ck::passed("Completed in " + ck::format(ck_elapsed_ms) + " ms");
        """, inputLine: context.inputLine)
}

// MARK: - Racket

func racketPerformanceCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let budgetMs: Double = {
        switch c.expected {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return 1000
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define budget-ms \(budgetMs))
        \(racketLoadAndGuard(family))

        (define start (current-inexact-milliseconds))
        (with-handlers ([exn:fail? (lambda (e)
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                               \(JSONValue.string(GeneratedMessage.performanceError).racketLiteral) (exn-message e))))])
          (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList)))
        (define elapsed (- (current-inexact-milliseconds) start))

        (if (<= elapsed budget-ms)
            (chickadee-passed (format "Completed in ~ams" (round elapsed)))
            (chickadee-failed (string-append "too slow\\n"
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.threshold).racketLiteral) (format "~ams" budget-ms) "\\n"
                               \(JSONValue.string(GeneratedMessage.elapsed).racketLiteral) (format "~ams" (round elapsed)))))
        """ + "\n"
}

// MARK: - Java

func javaPerformanceBody(
    target: String, context: JavaCallContext, c: PatternCase
) -> String {
    // The budget is authored in MILLISECONDS, like every other renderer.
    let budgetMs: String = {
        switch c.expected {
        case .int(let i): return String(Double(i))
        case .double(let d): return String(d)
        default: return "1000.0"
        }
    }()
    // Supportable for the same reason it is in C++: Java assignments are
    // native-only, so the two-substrate timing divergence that forces refusals
    // elsewhere cannot arise. The call is a bare statement rather than a bound
    // result — `var` cannot bind a void return, and a timed method may well be
    // void.
    //
    // No JIT warm-up loop, deliberately: warming would time the OPTIMISED
    // method, which is not what a student's single graded call costs, and it
    // would multiply every budget by the warm-up count.
    return javaGuarded(
        """
        long ckStarted = System.nanoTime();
        \(target)(\(context.callArgs));
        double ckElapsedMs = (System.nanoTime() - ckStarted) / 1e6;
        if (ckElapsedMs > \(budgetMs)) {
            ck.failed("too slow\\n"
                + \(context.inputLine)
                + "\(GeneratedMessage.threshold)" + ck.format(\(budgetMs)) + " ms\\n"
                + "\(GeneratedMessage.elapsed)" + ck.format(ckElapsedMs) + " ms");
        }
        ck.passed("Completed in " + ck.format(ckElapsedMs) + " ms");
        """, inputLine: context.inputLine)
}

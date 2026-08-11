// APIServer/Utilities/PatternFamilyRenderer+ReturnTypeCheck.swift
//
// `.returnTypeCheck` renderer.  Split from PatternFamilyRenderer.swift
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

// MARK: - returnTypeCheck

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
    // Type-name → check-expression mapping is shared with the notebook-check
    // `.variableExists` renderer (PythonScriptHelpers.swift).
    let typeCheckExpr = pythonTypeCheckExpression(typeName: typeName, valueExpr: "result")

    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
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
                _tb_src = f"\\n\(GeneratedMessage.source){_tb_frames[-1].line.strip()}"
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected)a {expected_type_name} return value\\n"
                f"\(GeneratedMessage.error){type(ex).__name__}: {ex}" + _tb_src + "\\n"            )

        if not (\(typeCheckExpr)):
            failed(
                "\(GeneratedMessage.wrongReturnType)\\n"
                \(ctx.inputLineLiteral)
                f"\(GeneratedMessage.expected){expected_type_name}\\n"
                f"\(GeneratedMessage.got){type(result).__name__} (value: {result!r})\\n"            )

        passed(f"Returned a {type(result).__name__}")
        """
}

// MARK: - R

/// `.returnTypeCheck` — the return value's type, not its value.
func rReturnTypeCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let ctx = rCallContext(for: family, case: c)
    let typeName: String = {
        if case .string(let s) = c.expected { return s }
        return "any"
    }()
    return """
        \(prelude)

        \(ctx.declBlock)expected_type_name <- \(JSONValue.string(typeName).rLiteral)

        student <- chickadee_load_student()
        target  <- chickadee_require_fn(student, \(JSONValue.string(family.functionName).rLiteral))

        result <- tryCatch(
            target(\(ctx.callArgs)),
            error = function(e) failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a ", expected_type_name, " return value\\n",
                "\(GeneratedMessage.error)", conditionMessage(e)))
        )

        if (!(\(rTypeCheckExpression(typeName: typeName, valueExpr: "result")))) {
            failed(paste0(
                "\(GeneratedMessage.wrongReturnType)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", expected_type_name, "\\n",
                "\(GeneratedMessage.got)", class(result)[[1L]], " (value: ", chickadee_format(result), ")"))
        }

        passed(paste0("Returned a ", class(result)[[1L]]))
        """
}

// MARK: - Lua

/// `.returnTypeCheck` — the return value's type, not its value.
func luaReturnTypeCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let typeName: String = {
        if case .string(let s) = c.expected { return s }
        return "any"
    }()
    return """
        \(prelude)

        \(ctx.declBlock)local expected_type_name = \(JSONValue.string(typeName).luaLiteral)

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a ", expected_type_name, " return value\\n",
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if not (\(luaTypeCheckExpression(typeName: typeName, valueExpr: "result"))) then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongReturnType)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", expected_type_name, "\\n",
                "\(GeneratedMessage.got)", type(result), " (value: ", chickadee.format(result), ")",
            }))
        end

        chickadee.passed("Returned a " .. type(result))
        """
}

// MARK: - Octave

/// `.returnTypeCheck` — the return value's type, not its value.
func octaveReturnTypeCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = octaveCallContext(for: family, case: c)
    let typeName: String = {
        if case .string(let s) = c.expected { return s }
        return "any"
    }()
    return """
        \(prelude)

        \(ctx.declBlock)expected_type_name = \(JSONValue.string(typeName).octaveLiteral);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).octaveLiteral));

        try
            result = target(\(ctx.callArgs));
        catch err
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a " expected_type_name " return value\\n" ...
                "\(GeneratedMessage.error)" err.message]);
        end

        if !(\(octaveTypeCheckExpression(typeName: typeName, valueExpr: "result")))
            chickadee.failed(["\(GeneratedMessage.wrongReturnType)\\n" ...
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)" expected_type_name "\\n" ...
                "\(GeneratedMessage.got)" class(result) " (value: " chickadee.format(result) ")"]);
        end

        chickadee.passed(["Returned a " class(result)]);
        """
}

// MARK: - C++

func cppReturnTypeBody(
    target: String, context: CppCallContext, c: PatternCase
) -> String {
    let expectedType: String = {
        if case .string(let s) = c.expected { return s }
        return "int"
    }()
    return cppGuarded(
        """
        auto result = \(target)(\(context.callArgs));
        if (!ck::type_matches<decltype(result)>("\(expectedType)")) {
            ck::failed(std::string("\(GeneratedMessage.wrongReturnType)\\n")
                + \(context.inputLine)
                + "\(GeneratedMessage.expected)\(expectedType)\\n"
                + "\(GeneratedMessage.got)" + ck::type_name<decltype(result)>());
        }
        ck::passed("\(GeneratedMessage.returned)a \(expectedType)");
        """, inputLine: context.inputLine)
}

// MARK: - Racket

func racketReturnTypeCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let expectedType: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected-type \(JSONValue.string(expectedType).racketLiteral))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (define actual-type (chickadee-type-name actual))
        (if (string=? actual-type expected-type)
            (chickadee-passed (string-append "Returned a " actual-type))
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-type "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) actual-type)))
        """ + "\n"
}

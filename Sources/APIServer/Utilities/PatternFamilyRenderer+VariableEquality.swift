// APIServer/Utilities/PatternFamilyRenderer+VariableEquality.swift
//
// `.variableEquality` renderer.  Split from PatternFamilyRenderer.swift
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

// MARK: - variableEquality

/// Renders a single-variable equality check.  `family.functionName` and
/// `family.paramNames` are ignored for this kind — the variable name lives
/// in `case.args[0]` (validated by `ManifestValidation` to be a non-empty
/// string) and the expected value in `case.expected`.  A sentinel default
/// on `getattr` distinguishes "not defined at all" from "defined as None"
/// so students get a useful error message in both cases.
func renderVariableEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    // Section + family variables are declared as module-level globals in
    // the generated test.  `variableEquality` is checking a STUDENT-module
    // attribute (not a declared-in-this-file one), so the section/family
    // variables don't interact with the check itself — but we still emit
    // them so the Variables row (e.g. a shared `patients` list) is
    // available if a future kind / hint references it.
    _ = sectionVariables  // currently unused by this kind; keep the signature consistent
    // Validation guarantees args.count == 1 and args[0] is a non-empty
    // string, but fall back to a sentinel name if somehow absent so the
    // generated Python is still syntactically valid.
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else {
            return "<unset>"
        }
        return name
    }()
    let nameLiteral = "\"" + escapeForPythonStringLiteral(variableName) + "\""

    // A per-student `expectedVarRef` is bound at grading time from
    // `_ck_inputs.py`; see personalizationPreambleForCase.  Note the variable
    // NAME (args[0]) stays a baked literal — only the expected VALUE
    // personalizes, which is why the validator still rejects arg refs here.
    // With no per-student refs the preamble is "" and `expectedExpression`
    // returns the same literal as before, so existing families render
    // byte-identically and their spec_hash / TestSetupCache keys don't churn.
    let preamble = personalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let preambleBlock = preamble.isEmpty ? "" : preamble + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(preambleBlock)variable_name = \(nameLiteral)
        expected      = \(expectedExpression(for: c))

        _MISSING = object()
        actual = getattr(student_module, variable_name, _MISSING)
        if actual is _MISSING:
            failed(
                f"Variable `{variable_name}` is not defined\\n"
                f"\(GeneratedMessage.expected){expected!r}\\n"            )

        if actual != expected:
            failed(
                f"Variable `{variable_name}` has the \(GeneratedMessage.wrongValue)\\n"
                f"\(GeneratedMessage.expected){expected!r}\\n"
                f"\(GeneratedMessage.got){actual!r}\\n"            )

        passed(f"{variable_name} == {actual!r}")
        """
}

// MARK: - R

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
func rVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else { return "<unset>" }
        return name
    }()
    return """
        \(prelude)

        variable_name <- \(JSONValue.string(variableName).rLiteral)
        expected      <- \(rExpectedExpression(for: c))

        student <- chickadee_load_student()
        .ck_missing <- structure(list(), class = "ck_missing")
        actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                           error = function(e) .ck_missing)

        if (inherits(actual, "ck_missing")) {
            failed(paste0(
                "Variable `", variable_name, "` is not defined\\n",
                "\(GeneratedMessage.expected)", chickadee_format(expected)))
        }

        if (!chickadee_equal(actual, expected)) {
            failed(paste0(
                "Variable `", variable_name, "` has the \(GeneratedMessage.wrongValue)\\n",
                "\(GeneratedMessage.expected)", chickadee_format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(actual)))
        }

        passed(paste0(variable_name, " == ", chickadee_format(actual)))
        """
}

// MARK: - Lua

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
func luaVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else { return "<unset>" }
        return name
    }()
    return """
        \(prelude)

        local variable_name = \(JSONValue.string(variableName).luaLiteral)
        local expected = \(luaExpectedExpression(for: c))

        local student = chickadee.load_student()
        local actual = rawget(student, variable_name)

        if actual == nil then
            chickadee.failed(table.concat({
                "Variable `", variable_name, "` is not defined\\n",
                "\(GeneratedMessage.expected)", chickadee.format(expected),
            }))
        end

        if not chickadee.equal(actual, expected) then
            chickadee.failed(table.concat({
                "Variable `", variable_name, "` has the \(GeneratedMessage.wrongValue)\\n",
                "\(GeneratedMessage.expected)", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(actual),
            }))
        end

        chickadee.passed(variable_name .. " == " .. chickadee.format(actual))
        """
}

// MARK: - Octave

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
func octaveVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else { return "<unset>" }
        return name
    }()
    return """
        \(prelude)

        variable_name = \(JSONValue.string(variableName).octaveLiteral);
        expected = \(octaveExpectedExpression(for: c));

        student = chickadee.load_student();

        if !chickadee.has_var(student, variable_name)
            chickadee.failed(["Variable `" variable_name "` is not defined\\n" ...
                "\(GeneratedMessage.expected)" chickadee.format(expected)]);
        end
        actual = chickadee.get_var(student, variable_name);

        if !chickadee.equal(actual, expected)
            chickadee.failed(["Variable `" variable_name "` has the \(GeneratedMessage.wrongValue)\\n" ...
                "\(GeneratedMessage.expected)" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(actual)]);
        end

        chickadee.passed([variable_name " == " chickadee.format(actual)]);
        """
}

// MARK: - C++

func cppVariableEqualityBody(
    family: PatternFamily, context: CppCallContext, c: PatternCase
) -> String {
    // The "function name" IS the variable name for this kind — a global in
    // the student's file, in scope through the single-TU include. Referencing
    // it is the existence check: missing → the wrapper's exit-2 diagnostic
    // names it.
    let variable = family.functionName
    return """
        auto expected = \(context.expectedExpression);
        if (!ck::equal(\(variable), expected)) {
            ck::failed(std::string("Variable `\(variable)` has the \(GeneratedMessage.wrongValue)\\n")
                + "\(GeneratedMessage.expected)" + ck::format(expected) + "\\n"
                + "\(GeneratedMessage.got)" + ck::format(\(variable)));
        }
        ck::passed("\(variable) is " + ck::format(\(variable)));
        """
}

// MARK: - Racket

/// `variableEquality` names a module-level VALUE rather than a function, so it
/// reads the binding with `chickadee-value`. Safe to evaluate bare even under
/// BSL: the operator-position restriction applies to procedures, not data.
func racketVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let target = racketArgumentName(family.functionName)
    return """
        \(prelude)

        (define expected \(racketExpected(c)))
        (define ns (chickadee-load-student))
        (unless (chickadee-defined? ns '\(target))
          (chickadee-failed \(JSONValue.string("`\(family.functionName)` is not defined").racketLiteral)))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append "the variable could not be read" "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-value ns '\(target))))

        (if (chickadee-equal? actual expected)
            (chickadee-passed (string-append "\(racketComment(family.functionName)) = " (chickadee-format actual)))
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.wrongValue).racketLiteral) "\\n"
                                                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

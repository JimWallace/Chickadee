// APIServer/Utilities/PatternFamilyRendererR.swift
//
// The R half of the pattern-family renderer: every `PatternKind` rendered as an
// `.R` test script, so an R assignment can use generated test families exactly
// like a Python one (issue: R/Python personalization parity).
//
// Why a separate file rather than branching inside the existing renderers: the
// Python bytes feed `spec_hash` and `TestSetupCache` keys, so they must stay
// byte-identical forever. Nothing here touches them — `patternKindHandler`
// dispatches on the assignment's language and this file owns the `.r` side.
// The R output has no legacy constraint, so it is written once, cleanly, with
// one `switch` over the kinds instead of eight handler types.
//
// Generated R leans on the injected runtime (`test_runtime.R`):
//   * `chickadee_load_student()` / `chickadee_require_fn()` locate and load the
//     submission (and centrally skip `_ck_inputs.R`, `test_runtime.R`, tests);
//   * `chickadee_equal` / `chickadee_unordered_equal` / `chickadee_format`
//     give the same comparison + failure-message shape as the Python side;
//   * `chickadee_inputs()` supplies per-student values from `_ck_inputs.R`.

import Core
import Foundation

// MARK: - Per-case R rendering

/// Renders one enabled case of `family` as an R test script.
func renderRPatternCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let header = rGeneratedCaseHeader(family: family, case: c, specHash: specHash)
    let variableBlock = rCombinedVariableDecls(sectionVariables: sectionVariables, family: family)
    let preamble = rPersonalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let prelude = [header, variableBlock, preamble].filter { !$0.isEmpty }.joined(separator: "\n\n")

    switch family.kind {
    case .boundaryEquality:
        return rEqualityCase(family: family, case: c, prelude: prelude, unordered: false)
    case .unorderedEquality:
        return rEqualityCase(family: family, case: c, prelude: prelude, unordered: true)
    case .approximateEquality:
        return rApproximateCase(family: family, case: c, prelude: prelude)
    case .variableEquality:
        return rVariableEqualityCase(family: family, case: c, prelude: prelude)
    case .returnTypeCheck:
        return rReturnTypeCase(family: family, case: c, prelude: prelude)
    case .exceptionExpected:
        return rExceptionCase(family: family, case: c, prelude: prelude)
    case .performanceThreshold:
        return rPerformanceCase(family: family, case: c, prelude: prelude)
    case .stdoutEquality:
        return rStdoutCase(family: family, case: c, prelude: prelude)
    case .differential:
        return rDifferentialCase(family: family, case: c, prelude: prelude)
    }
}

/// The R existence guard: the cases `dependsOn` it, so a missing or
/// non-function target fails once here and the cases skip through the runner's
/// dependency gate. Mirrors the Python guard's `failed()` (not `errored()`)
/// semantics so the gate behaves identically in both languages.
func renderRExistenceGuard(family: PatternFamily, specHash: String) -> String {
    let name = family.functionName
    return """
        # Test: \(name) is defined
        # Generated from pattern family "\(rComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
        # Existence guard: the family's cases depend on this test, so a missing
        # or non-function target fails once here and the cases skip instead of
        # erroring one by one.
        source("test_runtime.R")

        function_name <- \(JSONValue.string(name).rLiteral)

        student <- chickadee_load_student()
        target  <- tryCatch(get(function_name, envir = student, inherits = FALSE),
                            error = function(e) NULL)
        if (is.null(target)) {
            failed(paste0("`", function_name, "` is not defined — define a function named `",
                          function_name, "()` in your submission."))
        }
        if (!is.function(target)) {
            failed(paste0("`", function_name, "` is defined but is not a function (got ",
                          class(target)[[1L]], ")."))
        }
        passed(paste0("`", function_name, "` is defined"))
        """
}

// MARK: - Kind bodies

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
private func rEqualityCase(
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

/// `.differential` — compares the student's function against the instructor's
/// reference implementation, which is rendered verbatim above the call.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose, so the outcome is a
/// broken test and telling the student their function is wrong would send them
/// to debug the wrong code.
private func rDifferentialCase(
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

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
private func rApproximateCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
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

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
private func rVariableEqualityCase(
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

/// `.returnTypeCheck` — the return value's type, not its value.
private func rReturnTypeCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
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

/// `.exceptionExpected` — the call must raise. R has no exception class
/// hierarchy like Python's, so `expected` is matched against the condition's
/// class vector *or* its message (case-insensitive substring), which covers
/// both `stop("...")` and custom condition classes.
private func rExceptionCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
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

/// `.performanceThreshold` — the call must finish inside a millisecond budget.
private func rPerformanceCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
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

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
private func rStdoutCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
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

// MARK: - R template helpers

/// Per-case call context, the R analogue of `CallContext`. Omitted args on
/// defaulted params are skipped; everything after the first gap is passed by
/// name so R's argument matching binds the remaining values correctly.
struct RCallContext {
    /// `name <- <rLiteral>` lines plus a trailing blank line, or "" when the
    /// case takes no arguments.
    let declBlock: String
    /// The argument list as it appears inside `target(<here>)`.
    let callArgs: String
    /// R fragment for the `input:` line of a failure message, already
    /// terminated with a comma so it can be dropped into a `paste0(...)`.
    let inputLine: String
}

func rCallContext(for family: PatternFamily, case c: PatternCase) -> RCallContext {
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg_\($0 + 1)" }
    }()
    let provided: [Bool] = {
        guard !c.argsProvided.isEmpty else { return Array(repeating: true, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argsProvided.count ? c.argsProvided[i] : true }
    }()
    let varRefs: [String?] = {
        guard !c.argVarRefs.isEmpty else { return Array(repeating: nil, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argVarRefs.count ? c.argVarRefs[i] : nil }
    }()

    var declLines: [String] = []
    var callParts: [String] = []
    var previewParts: [String] = []
    var sawOmission = false
    for (idx, name) in argNames.enumerated() {
        guard idx < provided.count ? provided[idx] : true else {
            sawOmission = true
            continue
        }
        if let refName = idx < varRefs.count ? varRefs[idx] : nil {
            declLines.append("\(rIdentifier(name)) <- \(rIdentifier(refName))")
        } else if idx < c.args.count {
            declLines.append("\(rIdentifier(name)) <- \(c.args[idx].rLiteral)")
        }
        callParts.append(sawOmission ? "\(name) = \(rIdentifier(name))" : rIdentifier(name))
        previewParts.append("\"\(name)=\", chickadee_format(\(rIdentifier(name)))")
    }

    let inputLine: String
    if previewParts.isEmpty {
        inputLine = #""\#(GeneratedMessage.input)(no input)\n","#
    } else {
        let joined = previewParts.joined(separator: ", \", \", ")
        inputLine = "\"\(GeneratedMessage.input)\", \(joined), \"\\n\","
    }

    return RCallContext(
        declBlock: declLines.isEmpty ? "" : declLines.joined(separator: "\n") + "\n\n",
        callArgs: callParts.joined(separator: ", "),
        inputLine: inputLine
    )
}

/// Scope + family variables as `name <- <rLiteral>` lines. R evaluates top to
/// bottom, so the family's own variables come last and shadow section/global
/// ones — the same `family > section > global` precedence as Python.
func rCombinedVariableDecls(sectionVariables: [FamilyVariable], family: PatternFamily) -> String {
    let all = sectionVariables + family.variables
    guard !all.isEmpty else { return "" }
    return all.map { "\(rIdentifier($0.name)) <- \($0.value.rLiteral)" }.joined(separator: "\n")
}

/// Two-line provenance header plus the `source("test_runtime.R")` every
/// generated R script needs (R has no `sitecustomize` auto-import).
func rGeneratedCaseHeader(family: PatternFamily, case c: PatternCase, specHash: String) -> String {
    """
    # Test: \(rComment(c.label))
    # Generated from pattern family "\(rComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
    source("test_runtime.R")
    """
}

/// The R expression bound to `expected`: a bare identifier when the case pins
/// `expectedVarRef` (supplied per student via `_ck_inputs.R`), else the literal.
func rExpectedExpression(for c: PatternCase) -> String {
    if let ref = c.expectedVarRef, !ref.isEmpty { return rIdentifier(ref) }
    return c.expected.rLiteral
}

/// Per-student preamble: pulls the case's referenced names out of
/// `chickadee_inputs()` (which reads `_ck_inputs.R`, written by the runner from
/// the server-resolved values) and fails closed with a clear message when a
/// value is missing — the R mirror of `personalizationPreambleForCase`.
func rPersonalizationPreambleForCase(
    _ c: PatternCase, perStudentNames: Set<String>
) -> String {
    let names = perStudentRefsForCase(c, perStudentNames: perStudentNames)
    guard !names.isEmpty else { return "" }
    let bindings = names.map { name in
        """
        if (is.null(.ck_inputs_values[[\(JSONValue.string(name).rLiteral)]])) {
            failed(paste0("Personalization input '\(name)' is unavailable — is the assignment seed set?"))
        }
        \(rIdentifier(name)) <- .ck_inputs_values[[\(JSONValue.string(name).rLiteral)]]
        """
    }.joined(separator: "\n")
    return """
        # Per-student personalization inputs, resolved at grading time from the
        # assignment seed (see _ck_inputs.R, written by the runner). Do not edit.
        .ck_inputs_values <- chickadee_inputs()
        \(bindings)
        """
}

/// Maps an instructor-supplied type name to an R predicate. Python type names
/// are accepted too, so a family converted from a Python assignment keeps
/// working; anything unrecognised falls back to an S3/S4 class check.
func rTypeCheckExpression(typeName: String, valueExpr: String) -> String {
    switch typeName.lowercased() {
    case "numeric", "double", "float", "int", "integer", "number":
        return "is.numeric(\(valueExpr))"
    case "character", "str", "string":
        return "is.character(\(valueExpr))"
    case "logical", "bool", "boolean":
        return "is.logical(\(valueExpr))"
    case "list", "dict":
        return "is.list(\(valueExpr))"
    case "function", "callable":
        return "is.function(\(valueExpr))"
    case "data.frame", "dataframe":
        return "is.data.frame(\(valueExpr))"
    case "factor":
        return "is.factor(\(valueExpr))"
    case "matrix":
        return "is.matrix(\(valueExpr))"
    case "vector":
        return "is.vector(\(valueExpr))"
    case "null", "none":
        return "is.null(\(valueExpr))"
    case "any", "object":
        return "TRUE"
    default:
        return "inherits(\(valueExpr), \(JSONValue.string(typeName).rLiteral))"
    }
}

/// Back-tick quotes a name unless it is already a syntactic R identifier, so an
/// instructor's parameter/variable name can never produce unparseable R.
func rIdentifier(_ name: String) -> String {
    guard let first = name.first else { return "`_`" }
    let isSyntactic =
        (first.isLetter || first == ".")
        && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
    return isSyntactic ? name : "`\(name.replacingOccurrences(of: "`", with: ""))`"
}

/// Flattens a string for safe use inside a one-line `#` comment.
private func rComment(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

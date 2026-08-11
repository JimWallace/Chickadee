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

// THE PER-KIND RENDERERS ARE NOT HERE. Each one moved to
// `PatternFamilyRenderer+<Kind>.swift`, beside the other five languages'
// rendering of the same kind, so a kind can be reviewed across languages in one
// file. What remains is what is genuinely per-language: the kind dispatcher
// below, the call-context builder, the case header, the personalization
// preamble and the identifier/comment helpers.

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

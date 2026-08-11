// APIServer/Utilities/PatternFamilyRendererLua.swift
//
// The Lua half of the pattern-family renderer: every `PatternKind` rendered as
// a `.lua` test script, so a Lua assignment can use generated test families
// exactly like a Python or R one.
//
// Structured to mirror PatternFamilyRendererR.swift — one `switch` over the
// kinds, one small body each, sharing a call-context helper — because that file
// is the clean one. Python's is frozen: its bytes feed `spec_hash` and
// `TestSetupCache` keys, so it keeps its eight handler types and its historical
// shape. The student-facing WORDING is not duplicated in any of the three; all
// of them read `GeneratedMessage`.
//
// Generated Lua leans on the injected runtime (`test_runtime.lua`), bound as
// `chickadee` because `JSONValue.luaLiteral` emits `chickadee.NULL` for a JSON
// null inside a table and that name has to resolve:
//   * `chickadee.load_student()` / `chickadee.require_fn()` locate and load the
//     submission;
//   * `chickadee.equal` / `chickadee.unordered_equal` / `chickadee.format` give
//     the same comparison and failure-message shape as the other two languages;
//   * `chickadee.inputs()` supplies per-student values from `_ck_inputs.lua`.
//
// TWO LUA FACTS SHAPE EVERY BODY BELOW.
//
// `pcall` returns `(ok, resultOrError)` rather than taking handler callbacks, so
// the protected call is two statements where R's `tryCatch` is one expression.
//
// Lua has no keyword arguments. R passes everything after an omitted parameter
// by name so its argument matching still binds; Lua cannot, so a gap is passed
// as a positional `nil` — which is not a workaround but exactly right, since
// `function f(a, b) b = b or 10 end` is how Lua spells a default and `nil` is
// what triggers it. Trailing omissions are dropped instead, which has the same
// effect and reads better.

// THE PER-KIND RENDERERS ARE NOT HERE. Each one moved to
// `PatternFamilyRenderer+<Kind>.swift`, beside the other five languages'
// rendering of the same kind, so a kind can be reviewed across languages in one
// file. What remains is what is genuinely per-language: the kind dispatcher
// below, the call-context builder, the case header, the personalization
// preamble and the identifier/comment helpers.

import Core
import Foundation

// MARK: - Per-case Lua rendering

/// Renders one enabled case of `family` as a Lua test script.
func renderLuaPatternCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let header = luaGeneratedCaseHeader(family: family, case: c, specHash: specHash)
    let variableBlock = TestScriptVariablePrepender.emit(
        sectionVariables + family.variables, language: .lua)
    let preamble = luaPersonalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let prelude = [header, variableBlock, preamble].filter { !$0.isEmpty }.joined(separator: "\n\n")

    switch family.kind {
    case .boundaryEquality:
        return luaEqualityCase(family: family, case: c, prelude: prelude, unordered: false)
    case .unorderedEquality:
        return luaEqualityCase(family: family, case: c, prelude: prelude, unordered: true)
    case .approximateEquality:
        return luaApproximateCase(family: family, case: c, prelude: prelude)
    case .variableEquality:
        return luaVariableEqualityCase(family: family, case: c, prelude: prelude)
    case .returnTypeCheck:
        return luaReturnTypeCase(family: family, case: c, prelude: prelude)
    case .exceptionExpected:
        return luaExceptionCase(family: family, case: c, prelude: prelude)
    case .performanceThreshold:
        return luaPerformanceCase(family: family, case: c, prelude: prelude)
    case .stdoutEquality:
        return luaStdoutCase(family: family, case: c, prelude: prelude)
    case .differential:
        return luaDifferentialCase(family: family, case: c, prelude: prelude)
    }
}

/// The Lua existence guard: the cases `dependsOn` it, so a missing or
/// non-function target fails once here and the cases skip through the runner's
/// dependency gate.
///
/// Reads the binding directly rather than calling `chickadee.require_fn`, which
/// would `errored()` (exit 2) — the guard has to `failed()` (exit 1) to match
/// Python and R, because the dependency gate keys on a failure and an error
/// would leave the dependent cases running against a function that is not there.
func renderLuaExistenceGuard(family: PatternFamily, specHash: String) -> String {
    let name = family.functionName
    return """
        -- Test: \(luaComment(name)) is defined
        -- Generated from pattern family "\(luaComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
        -- Existence guard: the family's cases depend on this test, so a missing
        -- or non-function target fails once here and the cases skip instead of
        -- erroring one by one.
        local chickadee = require("test_runtime")

        local function_name = \(JSONValue.string(name).luaLiteral)

        local student = chickadee.load_student()
        local target = rawget(student, function_name)

        if target == nil then
            chickadee.failed("`" .. function_name .. "` is not defined — define a function named `"
                .. function_name .. "()` in your submission.")
        end
        if type(target) ~= "function" then
            chickadee.failed("`" .. function_name .. "` is defined but is not a function (got "
                .. type(target) .. ").")
        end
        chickadee.passed("`" .. function_name .. "` is defined")
        """
}

// MARK: - Kind bodies

// MARK: - Lua template helpers

/// Per-case call context, the Lua analogue of `CallContext` / `RCallContext`.
struct LuaCallContext {
    /// `local name = <luaLiteral>` lines plus a trailing blank line, or "" when
    /// the case takes no arguments.
    let declBlock: String
    /// The argument list as it appears after `pcall(target` — including the
    /// leading comma, or "" for a no-argument call, so the call site never has
    /// to decide whether a separator is needed.
    let callArgsSuffix: String
    /// Lua fragment for the `input:` line of a failure message, already
    /// terminated with a comma so it drops into a `table.concat{...}`.
    let inputLine: String
}

func luaCallContext(for family: PatternFamily, case c: PatternCase) -> LuaCallContext {
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
    for (idx, name) in argNames.enumerated() {
        guard idx < provided.count ? provided[idx] : true else {
            // A gap becomes a positional `nil`. Trailing gaps are trimmed
            // below, since dropping them has the same effect and reads better.
            callParts.append("nil")
            continue
        }
        if let refName = idx < varRefs.count ? varRefs[idx] : nil {
            declLines.append("local \(luaIdentifier(name)) = \(luaIdentifier(refName))")
        } else if idx < c.args.count {
            declLines.append("local \(luaIdentifier(name)) = \(c.args[idx].luaLiteral)")
        }
        callParts.append(luaIdentifier(name))
        previewParts.append("\"\(name)=\", chickadee.format(\(luaIdentifier(name)))")
    }
    while callParts.last == "nil" { callParts.removeLast() }

    let inputLine: String
    if previewParts.isEmpty {
        inputLine = "\"\(GeneratedMessage.input)(no input)\\n\","
    } else {
        let joined = previewParts.joined(separator: ", \", \", ")
        inputLine = "\"\(GeneratedMessage.input)\", \(joined), \"\\n\","
    }

    return LuaCallContext(
        declBlock: declLines.isEmpty ? "" : declLines.joined(separator: "\n") + "\n\n",
        callArgsSuffix: callParts.isEmpty ? "" : ", " + callParts.joined(separator: ", "),
        inputLine: inputLine
    )
}

/// Two-line provenance header plus the `require` every generated Lua script
/// needs. The `-- Test:` line MUST come first so `chickadee.label()` and the
/// runner's first-comment label agree with the other two languages.
func luaGeneratedCaseHeader(
    family: PatternFamily, case c: PatternCase, specHash: String
) -> String {
    """
    -- Test: \(luaComment(c.label))
    -- Generated from pattern family "\(luaComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
    local chickadee = require("test_runtime")
    """
}

/// The Lua expression bound to `expected`: a bare identifier when the case pins
/// `expectedVarRef` (supplied per student via `_ck_inputs.lua`), else the literal.
func luaExpectedExpression(for c: PatternCase) -> String {
    if let ref = c.expectedVarRef, !ref.isEmpty { return luaIdentifier(ref) }
    return c.expected.luaLiteral
}

/// Per-student preamble: pulls the case's referenced names out of
/// `chickadee.inputs()` and fails closed with a clear message when a value is
/// missing — the Lua mirror of `personalizationPreambleForCase`.
func luaPersonalizationPreambleForCase(
    _ c: PatternCase, perStudentNames: Set<String>
) -> String {
    let names = perStudentRefsForCase(c, perStudentNames: perStudentNames)
    guard !names.isEmpty else { return "" }
    let bindings = names.map { name in
        """
        if ck_inputs_values[\(JSONValue.string(name).luaLiteral)] == nil then
            chickadee.failed("Personalization input '\(name)' is unavailable — is the assignment seed set?")
        end
        local \(luaIdentifier(name)) = ck_inputs_values[\(JSONValue.string(name).luaLiteral)]
        """
    }.joined(separator: "\n")
    return """
        -- Per-student personalization inputs, resolved at grading time from the
        -- assignment seed (see _ck_inputs.lua, written by the runner). Do not edit.
        local ck_inputs_values = chickadee.inputs()
        \(bindings)
        """
}

/// Maps an instructor-supplied type name to a Lua predicate.
///
/// Lua has eight types and no `int`/`float` distinction at the `type()` level,
/// so the numeric names all collapse to `"number"` — with `integer` checked
/// through `math.type`, which is the only place 5.4's integer subtype is
/// observable. Python and R type names are accepted too, so a family converted
/// from either keeps working.
func luaTypeCheckExpression(typeName: String, valueExpr: String) -> String {
    switch typeName.lowercased() {
    case "int", "integer":
        return "math.type(\(valueExpr)) == \"integer\""
    case "number", "numeric", "double", "float":
        return "type(\(valueExpr)) == \"number\""
    case "str", "string", "character":
        return "type(\(valueExpr)) == \"string\""
    case "bool", "boolean", "logical":
        return "type(\(valueExpr)) == \"boolean\""
    case "table", "list", "dict", "array":
        return "type(\(valueExpr)) == \"table\""
    case "function", "callable":
        return "type(\(valueExpr)) == \"function\""
    case "nil", "none", "null":
        return "\(valueExpr) == nil"
    case "any", "object":
        return "true"
    default:
        // An unrecognised name is compared against `type()` directly, so a
        // future Lua type (or a typo) reports as a mismatch rather than
        // silently passing the way an `any` fallback would.
        return "type(\(valueExpr)) == \(JSONValue.string(typeName.lowercased()).luaLiteral)"
    }
}

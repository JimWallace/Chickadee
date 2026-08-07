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

/// `.boundaryEquality` / `.unorderedEquality` — call the function, compare the
/// return value (exactly, or ignoring order).
private func luaEqualityCase(
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

/// `.approximateEquality` — numeric return within a tolerance, reporting the
/// actual delta so a student sees how far off they are.
private func luaApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = luaCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).luaLiteral
    return """
        \(prelude)

        \(ctx.declBlock)local expected = \(luaExpectedExpression(for: c))
        local tolerance = \(tolerance)

        local student = chickadee.load_student()
        local target = chickadee.require_fn(student, \(JSONValue.string(family.functionName).luaLiteral))

        local ok, result = pcall(target\(ctx.callArgsSuffix))
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), " (±", tostring(tolerance), ")\\n",
                "\(GeneratedMessage.error)", tostring(result),
            }))
        end

        if type(result) ~= "number" then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongReturnType)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)a single number close to ", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(result),
            }))
        end

        local delta = math.abs(result - expected)
        if delta > tolerance then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.outsideTolerance)\\n",
                \(ctx.inputLine)
                "\(GeneratedMessage.expected)", chickadee.format(expected), " (±", tostring(tolerance), ")\\n",
                "\(GeneratedMessage.got)", chickadee.format(result), "\\n",
                "\(GeneratedMessage.delta)", chickadee.format(delta),
            }))
        end

        chickadee.passed("\(GeneratedMessage.returned)" .. chickadee.format(result) .. " (within ±" .. tostring(tolerance) .. ")")
        """
}

/// `.variableEquality` — a module-level variable, not a function call. The
/// variable name lives in `args[0]`; `expected` holds its value.
private func luaVariableEqualityCase(
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

/// `.returnTypeCheck` — the return value's type, not its value.
private func luaReturnTypeCase(
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

/// `.exceptionExpected` — the call must raise.
///
/// Lua has no exception hierarchy and no exception TYPE: `error("boom")` raises
/// a string, `error({code = 1})` raises a table, and neither carries a class. So
/// `expected` is matched case-insensitively against the rendered error value,
/// which is the only thing every raise has in common. R matches against the
/// condition's class vector OR its message for the same reason; Python, which
/// does have a hierarchy, walks the MRO instead.
private func luaExceptionCase(
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
private func luaPerformanceCase(
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

/// `.stdoutEquality` — what the call prints, compared after trimming trailing
/// whitespace on each line (so a stray trailing space is not a failure).
///
/// Lua has no `capture.output`, so `print` and `io.write` are swapped for
/// collectors around the call and restored afterwards. They are swapped in the
/// STUDENT's environment table, not in `_G`: the submission is loaded with
/// `__index = _G`, so an assignment into its own table shadows the global for
/// the student's code while leaving the harness's own `print` untouched — which
/// matters because `chickadee.failed` writes the result JSON with `io.write`.
private func luaStdoutCase(
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
        student.io = setmetatable(
            { write = function(...)
                for i = 1, select("#", ...) do
                    captured[#captured + 1] = tostring((select(i, ...)))
                end
            end },
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

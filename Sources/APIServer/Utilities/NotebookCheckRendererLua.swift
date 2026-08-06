// APIServer/Utilities/NotebookCheckRendererLua.swift
//
// The Lua half of the notebook-check renderer.
//
// WHICH KINDS LUA SUPPORTS, AND WHY IT IS FEWER THAN R'S NINE. This is answered
// from what the `chickadee-lua` environment actually contains, not by copying
// the neighbour: that env is bare `xeus-lua`, because emscripten-forge-4x ships
// no Lua library packages at all (see Tools/jupyterlite/environment-lua.yml).
//
//   * The four data-frame kinds (`dataFrameShape`, `dataFrameColumns`,
//     `dataFrameEquality`, `seriesEquality`) need a data frame. Lua has no such
//     type and no package provides one — a table of tables is not a data frame
//     and pretending otherwise would produce checks that pass or fail for
//     reasons unrelated to what the instructor asked.
//   * `figureCount` needs a plotting library that counts figures. Lua has none,
//     and unlike the data-frame kinds there is not even a shape to approximate.
//   * `astStructure` is Python-only by design, as it is for R.
//
// That leaves four, and they are the four that need nothing but the language:
// `variableExists`, `functionExists`, `numericArrayClose`, `cellContains`.
//
// Declaring the gap is the point. `NotebookCheckValidator` rejects an
// unsupported kind at SAVE time with a message naming what this language does
// support, so an instructor finds out while authoring rather than through a
// grading error — and `everyNotebookCheckKindRendersOrIsADeclaredException` in
// the conformance matrix requires each exception to be listed explicitly, so a
// kind cannot go missing by accident.

import Core
import Foundation

/// Whether `kind` has a Lua renderer. See the file comment for the reasoning
/// behind each exclusion.
func notebookCheckKindSupportsLua(_ kind: NotebookCheckKind) -> Bool {
    switch kind {
    case .variableExists, .functionExists, .numericArrayClose, .cellContains:
        return true
    case .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality,
        .figureCount, .astStructure:
        return false
    }
}

/// Renders one notebook check as a Lua test script. Callers must have already
/// gated on `notebookCheckKindSupportsLua`; an unsupported kind renders a script
/// that fails with an explicit message rather than trapping, so a spec that
/// slips past validation still produces a readable result.
func renderLuaNotebookCheck(_ check: NotebookCheck, specHash: String) -> String {
    switch check.kind {
    case .variableExists: return renderLuaVariableExists(check, specHash: specHash)
    case .functionExists: return renderLuaFunctionExists(check, specHash: specHash)
    case .numericArrayClose: return renderLuaNumericArrayClose(check, specHash: specHash)
    case .cellContains: return renderLuaCellContains(check, specHash: specHash)
    case .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality,
        .figureCount, .astStructure:
        return luaUnsupportedCheck(check, specHash: specHash)
    }
}

// MARK: - Shared preamble

/// The provenance header plus the runtime require every generated Lua check
/// opens with. The `-- Test:` line MUST come first so the runner's label
/// extraction agrees across languages.
private func luaCheckHeader(_ check: NotebookCheck, specHash: String, label: String) -> String {
    """
    -- Test: \(luaComment(label))
    -- Generated from notebook check [\(check.id)] spec_hash=\(specHash) — edit the check, not this file.
    local chickadee = require("test_runtime")
    """
}

/// A check whose kind has no Lua renderer. Fails with a message that names the
/// kind, rather than trapping or silently passing — a check that quietly passed
/// would award marks nobody verified.
private func luaUnsupportedCheck(_ check: NotebookCheck, specHash: String) -> String {
    """
    \(luaCheckHeader(check, specHash: specHash, label: "unsupported check"))

    chickadee.errored("The '\(luaComment(check.kind.rawValue))' notebook check is not available for Lua assignments.")
    """
}

// MARK: - Kind bodies

/// `.variableExists` — the submission defines a variable, optionally of a
/// stated type.
private func renderLuaVariableExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? ""
    let typeGuard: String = {
        guard let expected = check.expectedType, !expected.isEmpty else { return "" }
        return """


                if not (\(luaTypeCheckExpression(typeName: expected, valueExpr: "actual"))) then
                    chickadee.failed(table.concat({
                        "Variable `", variable_name, "` has the \(GeneratedMessage.wrongReturnType)\\n",
                        "\(GeneratedMessage.expected)", \(JSONValue.string(expected).luaLiteral), "\\n",
                        "\(GeneratedMessage.got)", type(actual),
                    }))
                end
            """
    }()
    return """
        \(luaCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) is defined"))

        local variable_name = \(JSONValue.string(name).luaLiteral)

        local student = chickadee.load_student()
        local actual = rawget(student, variable_name)

        if actual == nil then
            chickadee.failed("Variable `" .. variable_name .. "` is not defined in your notebook.")
        end\(typeGuard)

        chickadee.passed("`" .. variable_name .. "` is defined")
        """
}

/// `.functionExists` — the submission defines a callable of the given name.
private func renderLuaFunctionExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? ""
    return """
        \(luaCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) is defined"))

        local function_name = \(JSONValue.string(name).luaLiteral)

        local student = chickadee.load_student()
        local target = rawget(student, function_name)

        if target == nil then
            chickadee.failed("`" .. function_name .. "` is not defined — define a function named `"
                .. function_name .. "()` in your notebook.")
        end
        if type(target) ~= "function" then
            chickadee.failed("`" .. function_name .. "` is defined but is not a function (got "
                .. type(target) .. ").")
        end

        chickadee.passed("`" .. function_name .. "` is defined")
        """
}

/// `.numericArrayClose` — a numeric sequence within a tolerance, element by
/// element, reporting the first element that is out.
private func renderLuaNumericArrayClose(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? "array"
    let expected = check.expectedArray ?? []
    // numpy's `assert_allclose` defaults, the same pair the Python and R
    // renderers of this kind use, so a check authored against either keeps its
    // tolerance when the course moves to Lua.
    let rtol = JSONValue.double(check.rtol ?? 1e-7).luaLiteral
    let atol = JSONValue.double(check.atol ?? 0.0).luaLiteral
    let expectedLiteral =
        "{" + expected.map { JSONValue.double($0).luaLiteral }.joined(separator: ", ") + "}"
    return """
        \(luaCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) values"))

        local variable_name = \(JSONValue.string(name).luaLiteral)
        local expected = \(expectedLiteral)
        local rtol = \(rtol)
        local atol = \(atol)

        local student = chickadee.load_student()
        local actual = rawget(student, variable_name)

        if actual == nil then
            chickadee.failed("Variable `" .. variable_name .. "` is not defined in your notebook.")
        end
        if type(actual) ~= "table" then
            chickadee.failed(table.concat({
                "Variable `", variable_name, "` could not be read as a sequence of numbers.\\n",
                "\(GeneratedMessage.got)", type(actual),
            }))
        end
        if #actual ~= #expected then
            chickadee.failed(table.concat({
                "Variable `", variable_name, "` has the wrong length.\\n",
                "\(GeneratedMessage.expected)", tostring(#expected), " values\\n",
                "\(GeneratedMessage.got)", tostring(#actual), " values",
            }))
        end

        -- Mirrors numpy's allclose, including its equal_nan default: two NaNs
        -- agree, and two infinities of the same sign agree. Non-finite
        -- positions are settled by those two rules alone and never by the
        -- tolerance — `rtol * inf` is `inf`, which would otherwise make every
        -- infinity match every other one.
        --
        -- Lua spells the two tests without library help: NaN is the only value
        -- that is not equal to itself, and the infinities are exactly
        -- `math.huge` and its negation.
        local function is_nan(x) return x ~= x end
        local function is_inf(x) return x == math.huge or x == -math.huge end

        for i = 1, #expected do
            local a, e = actual[i], expected[i]
            if type(a) ~= "number" then
                chickadee.failed(table.concat({
                    "Variable `", variable_name, "` contains a value that is not a number.\\n",
                    "\(GeneratedMessage.position)", tostring(i), "\\n",
                    "\(GeneratedMessage.got)", chickadee.format(a),
                }))
            end
            local ok
            if is_nan(a) or is_nan(e) then
                ok = is_nan(a) and is_nan(e)
            elseif is_inf(a) or is_inf(e) then
                ok = is_inf(a) and is_inf(e) and ((a > 0) == (e > 0))
            else
                ok = math.abs(a - e) <= (atol + rtol * math.abs(e))
            end
            if not ok then
                chickadee.failed(table.concat({
                    "Variable `", variable_name, "` is not close enough to expected.\\n",
                    "\(GeneratedMessage.position)", tostring(i), "\\n",
                    "\(GeneratedMessage.expected)", chickadee.format(e), "\\n",
                    "\(GeneratedMessage.got)", chickadee.format(a),
                }))
            end
        end

        chickadee.passed("`" .. variable_name .. "` matches all " .. tostring(#expected) .. " expected value(s)")
        """
}

/// `.cellContains` — a source-level check: some cell of the notebook contains
/// the given text. Reads `chickadee.student_cells()`, which splits on the inert
/// cell markers `extractLua` writes.
///
/// FIXED MATCHING ONLY. Python matches with `re` and R with PCRE
/// (`grepl(perl = TRUE)`), which are close enough that a pattern transfers
/// between them. Lua patterns are a DIFFERENT language, not a dialect: there is
/// no alternation, no `{n,m}`, and character classes are `%d` rather than `\\d`.
/// A PCRE authored against the Python renderer would not error under Lua — it
/// would quietly match the wrong thing, or nothing, and award or withhold marks
/// on that basis. `NotebookCheckValidator` therefore rejects `regex: true` on a
/// Lua assignment at SAVE time, so the instructor is told while authoring; this
/// renderer only ever emits the fixed form.
private func renderLuaCellContains(_ check: NotebookCheck, specHash: String) -> String {
    let needle = check.containsText ?? ""
    let label = check.name ?? notebookCheckKindHandler(for: check.kind).defaultLabel(check)

    let mustDifferBlock: String
    if let mustDiffer = check.mustDifferFrom {
        mustDifferBlock = """
            local must_differ_from = \(JSONValue.string(mustDiffer).luaLiteral)
            -- Whitespace-normalize both sides, so trailing newlines or a
            -- re-indent don't disguise a copy of the example.
            local function ck_normalize(s)
                return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
            end
            local reference = ck_normalize(must_differ_from)
            local all_identical = true
            for _, cell in ipairs(matched) do
                if ck_normalize(cell) ~= reference then
                    all_identical = false
                    break
                end
            end
            if all_identical then
                chickadee.failed(table.concat({
                    "The cell containing `", needle, "` is identical to the example.\\n",
                    "\(GeneratedMessage.expected)a cell that contains `", needle, "` AND differs from the example\\n",
                    "\(GeneratedMessage.hint)write your own version, not a copy of the prompt's example",
                }))
            end
            """
    } else {
        mustDifferBlock = "-- (no must-differ-from constraint)"
    }

    return """
        \(luaCheckHeader(check, specHash: specHash, label: label))

        local needle = \(JSONValue.string(needle).luaLiteral)

        local cells = chickadee.student_cells()
        local matched = {}
        for _, cell in ipairs(cells) do
            -- The trailing `true` is plain-find: metacharacters in the
            -- instructor's text are matched literally, never interpreted.
            if string.find(cell, needle, 1, true) then
                matched[#matched + 1] = cell
            end
        end

        if #matched == 0 then
            chickadee.failed(table.concat({
                "No code cell in your notebook matches `", needle, "`.\\n",
                "\(GeneratedMessage.expected)at least one cell containing the pattern\\n",
                "\(GeneratedMessage.searched)", tostring(#cells), " code cell(s)",
            }))
        end

        \(mustDifferBlock)

        chickadee.passed("Found " .. tostring(#matched) .. " cell(s) containing `" .. needle .. "`")
        """
}

// Core/LuaPersonalizationRuntime.swift
//
// Lua source snippets shared by the two places that need Lua personalization
// primitives: the injected grading runtime (test_runtime.lua, via the worker's
// TestRuntimeSources) and the server-side Lua expression driver
// (PersonalizationEvaluator). One source of truth means the seed the driver
// binds and the seed a grading script reads are computed identically.
//
// The Lua counterpart of RPersonalizationRuntime, and it exists now for the
// reason TestRuntimeSources predicted it would: the seed was a lone literal in
// test_runtime.lua while there was no driver to share it with. There is one now.
//
// Standard library only. The `chickadee-lua` environment is bare `xeus-lua` and
// the runner image installs plain `lua5.4`, so anything beyond the base library
// is unavailable in both places this is used.

public enum LuaPersonalizationRuntime {

    /// `chickadee_seed()` — a deterministic integer derived from the per-student
    /// `CHICKADEE_ASSIGNMENT_SEED` (a 64-hex-char / 256-bit value).
    ///
    /// Lua 5.4 has 64-bit integers but no bignum, so the hex cannot be converted
    /// directly. The digits are folded with Horner's method modulo `2^31 - 1` —
    /// the SAME reduction base R uses, deliberately, so a student's seed is one
    /// number whichever of the two non-Python languages the assignment is in.
    /// Every intermediate stays below `2^35`, well inside both Lua's integers
    /// and the doubles the browser kernel may fall back to.
    ///
    /// Emitted as a bare global function rather than a module member, because
    /// the driver script has no `test_runtime` beside it to require — the
    /// runtime is injected into the grading workspace, not the personalization
    /// temp directory. `test_runtime.lua` wraps the identical body as `M.seed`.
    public static let chickadeeSeedLuaSource = #"""
        local function chickadee_seed()
            local raw = os.getenv("CHICKADEE_ASSIGNMENT_SEED") or ""
            local hex = raw:lower():gsub("[^0-9a-f]", "")
            if hex == "" then return 0 end
            local modulus = 2147483647  -- 2^31 - 1; intermediates stay well inside 2^53
            local acc = 0
            for i = 1, #hex do
                acc = (acc * 16 + tonumber(hex:sub(i, i), 16)) % modulus
            end
            return math.tointeger(acc) or acc
        end
        """#

    /// A Lua value rendered back as Lua source, for the driver's output stage.
    ///
    /// The counterpart of R's `deparse` and Python's `repr`, neither of which
    /// Lua has. The server parses nothing here — it takes the emitted text and
    /// writes it verbatim into `_ck_inputs.lua`, so this has to produce a Lua
    /// LITERAL rather than a display form.
    ///
    /// Two details are load-bearing:
    ///   * `%.17g` for floats, which round-trips an IEEE double exactly, and an
    ///     integer check first so `3` does not become `3.0` (Lua 5.4
    ///     distinguishes them, and a student comparing against `3` should see
    ///     `3`).
    ///   * `%q` for strings, which is Lua's own escaping and is guaranteed to
    ///     read back as the same string.
    ///
    /// Only array-like tables are serialised, one level of nesting at a time via
    /// recursion; anything else (a function, a coroutine, userdata) has no
    /// literal form and is rendered `nil`, which surfaces as a missing
    /// personalization input rather than as unparseable source.
    public static let chickadeeSerializeLuaSource = #"""
        local function chickadee_serialize(value)
            local kind = type(value)
            if value == nil then
                return "nil"
            elseif kind == "boolean" then
                return tostring(value)
            elseif kind == "number" then
                if math.type(value) == "integer" then return string.format("%d", value) end
                if value ~= value then return "(0/0)" end
                if value == math.huge then return "(1/0)" end
                if value == -math.huge then return "(-1/0)" end
                return string.format("%.17g", value)
            elseif kind == "string" then
                return string.format("%q", value)
            elseif kind == "table" then
                local parts = {}
                for i = 1, #value do
                    parts[#parts + 1] = chickadee_serialize(value[i])
                end
                return "{" .. table.concat(parts, ", ") .. "}"
            end
            return "nil"
        end
        """#

    /// JSON string encoder for the driver's output stage.
    ///
    /// Byte-identical in behaviour to `json_str` in `test_runtime.lua`; kept
    /// here rather than shared with it because the runtime's copy is a local
    /// inside that module and the driver needs a standalone one.
    public static let chickadeeJSONStringLuaSource = #"""
        local function chickadee_json_str(value)
            local s = tostring(value)
            s = s:gsub("\\", "\\\\")
            s = s:gsub('"', '\\"')
            s = s:gsub("\n", "\\n")
            s = s:gsub("\r", "\\r")
            s = s:gsub("\t", "\\t")
            return '"' .. s .. '"'
        end
        """#

    /// The `chickadee.NULL` sentinel VALUE, as Lua source.
    ///
    /// Lua has no missing-value scalar and a bare `nil` in a table constructor
    /// is not stored at all, so `JSONValue.luaLiteral` emits `chickadee.NULL`
    /// for a null inside any table — which requires something to exist under
    /// that name wherever a rendered literal is evaluated.
    ///
    /// Two places evaluate them: the grading runtime (`test_runtime.lua`, which
    /// binds this as `M.NULL`) and the in-page auto-compute worker (which has no
    /// `test_runtime` loaded and binds it as `chickadee.NULL` directly). Only
    /// the expression is shared, because the two bind it differently.
    ///
    /// Compared by identity, so nothing a student can construct equals it.
    public static let chickadeeNullSentinelLuaSource =
        #"setmetatable({}, { __tostring = function() return "NULL" end })"#

    /// What the in-page auto-compute worker must define before it evaluates a
    /// rendered Lua literal: the `chickadee` table carrying the sentinel.
    ///
    /// The grading path gets this from `require("test_runtime")`. The eval
    /// worker loads no such module — it evaluates the instructor's solution
    /// cells and nothing else — so without this a null inside any argument
    /// would index a nil `chickadee` and report as a confusing solution error.
    public static let chickadeeNullTableLuaSource = """
        chickadee = chickadee or {}
        chickadee.NULL = chickadee.NULL or \(chickadeeNullSentinelLuaSource)
        """

    /// Re-binds the two helper functions above as globals.
    ///
    /// `chickadee_serialize` and `chickadee_json_str` are declared `local`,
    /// which is right for the server driver — one script, one chunk, and a
    /// driver that leaks globals into an instructor's expression scope would be
    /// a surprise. In a kernel it is not enough: EVERY CELL IS ITS OWN CHUNK, so
    /// a `local` declared while seeding the runtime is gone by the time the
    /// first snippet runs, and the snippet's call reads as "attempt to call a
    /// nil value" — a per-cell error rather than the substrate failure it is.
    ///
    /// This tail runs inside the same chunk as the declarations, which is the
    /// only place the locals are still in scope.
    public static let chickadeeAutoComputeExportsLuaSource = """
        _G.chickadee_serialize = chickadee_serialize
        _G.chickadee_json_str = chickadee_json_str
        """
}

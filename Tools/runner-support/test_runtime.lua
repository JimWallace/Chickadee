-- test_runtime.lua — Chickadee Lua test helper library.
-- Require at the top of each Lua test script:
--     local t = require("test_runtime")
--
-- API (a module table, the Lua idiom — R sources a file and Python imports
-- names, but a Lua library that assigned globals would be a surprise):
--   t.passed(message)            — exit 0  (pass)
--   t.failed(message)            — exit 1  (fail)
--   t.errored(message)           — exit 2  (error)
--   t.label()                    — the test's name, from arg[0]
--   t.seed()                     — deterministic per-student integer seed
--   t.inputs()                   — per-student inputs from _ck_inputs.lua
--   t.student_file()             — the submitted .lua file to grade
--   t.load_student()             — that file, loaded into a fresh environment
--   t.require_fn(env, name)      — fetch a function the student had to write
--   t.format(value)              — one-line rendering, for failure messages
--   t.equal(a, b)                — value equality across Lua's number types
--
-- No external dependencies: JSON is hand-formatted, so this works on a bare
-- `lua` install and inside the xeus-lua kernel alike.
--
-- WHAT MAKES THIS FILE WORK IN BOTH RUNNERS, which is the whole difficulty.
-- The native runner spawns `lua publictest_foo.lua`, so the contract is a
-- PROCESS contract: os.exit sets the status, arg[0] names the script,
-- os.getenv reads the environment. A xeus-lua kernel has none of those — there
-- is no process to exit and no argv. Rather than fork this file, the browser
-- wrapper (Public/lua-grading-shared.js) re-creates that contract inside one
-- Lua session by masking `os.exit`, `os.getenv` and `arg` before the script
-- runs. This file therefore stays byte-identical across both runners, exactly
-- as test_runtime.R does. Do not replace os.exit with a `return`-based
-- protocol: under `lua` that would exit 0 for a failing test.

local M = {}

local function json_str(value)
    local s = tostring(value)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return '"' .. s .. '"'
end

-- The test's name, as the grader labels it: the script filename without its
-- directory or extension. `arg` is what `lua script.lua` populates and what
-- the browser wrapper masks, so both runners answer the same thing.
function M.label()
    local path = (type(arg) == "table" and arg[0]) or ""
    local base = path:match("([^/\\]+)$") or path
    local stem = base:match("^(.*)%.[^.]*$") or base
    if stem == "" then return "test" end
    return stem
end

-- The script currently executing, with its extension — never mistakable for
-- the student's submission when scanning the working directory.
local function running_script()
    local path = (type(arg) == "table" and arg[0]) or ""
    return path:match("([^/\\]+)$") or ""
end

local function emit(status, short_result, err)
    local parts = {
        '"status":' .. json_str(status),
        '"shortResult":' .. json_str(short_result),
        '"test":' .. json_str(M.label()),
    }
    if err ~= nil then
        parts[#parts + 1] = '"error":' .. json_str(err)
    end
    io.write("{" .. table.concat(parts, ",") .. "}\n")
end

function M.passed(message)
    local msg = message ~= nil and tostring(message) or (M.label() .. ": passed")
    emit("pass", msg)
    os.exit(0)
end

function M.failed(message)
    local msg = tostring(message == nil and "failed" or message)
    emit("fail", M.label() .. ": " .. msg, msg)
    os.exit(1)
end

function M.errored(message)
    local msg = tostring(message == nil and "error" or message)
    emit("error", M.label() .. ": " .. msg, msg)
    os.exit(2)
end

-- --- Value formatting + comparison -----------------------------------------
-- Used by hand-authored tests so failure messages read the same whatever
-- produced them. The Lua analogue of chickadee_format / chickadee_equal in
-- test_runtime.R.

-- One-line, student-readable rendering. Tables are shown one level deep with
-- their array part in order, which is what a test's expected value normally
-- is; anything deeper is elided rather than recursed, so a cyclic table cannot
-- hang the grader.
function M.format(value, max_chars)
    max_chars = max_chars or 300
    local rendered
    if type(value) == "string" then
        rendered = string.format("%q", value)
    elseif type(value) ~= "table" then
        rendered = tostring(value)
    else
        local parts = {}
        for _, item in ipairs(value) do
            parts[#parts + 1] = type(item) == "table" and "{...}" or tostring(item)
        end
        rendered = "{" .. table.concat(parts, ", ") .. "}"
    end
    if #rendered > max_chars then
        return rendered:sub(1, max_chars) .. " ..."
    end
    return rendered
end

-- The stand-in for a JSON null inside a generated table literal.
--
-- Lua has no missing-value scalar, and a bare `nil` in a table constructor is
-- not stored at all: `{60, nil, 20}` makes `ipairs` stop after one element and
-- `table.concat` raise, so an authored case's positional alignment is silently
-- lost. A sentinel TABLE is a real value and occupies its slot. This is Lua's
-- answer to the problem R solves with `NA` (see `JSONValue.luaLiteral`, which
-- emits `chickadee.NULL` and is what requires this to exist under that name).
--
-- Compared by identity, so nothing a student can construct is equal to it.
M.NULL = setmetatable({}, { __tostring = function() return "NULL" end })

-- Exact equality, with Lua 5.4's integer/float split handled the way a student
-- would expect: 1 and 1.0 are the same answer. `==` already says so for
-- numbers, so the only work is comparing array-like tables element by element.
--
-- `M.NULL` is equal only to itself. It must be checked BEFORE the table arm,
-- or two distinct sentinels would compare equal as empty tables — which would
-- be harmless today but wrong the moment a student returned `{}`.
function M.equal(actual, expected)
    if actual == M.NULL or expected == M.NULL then
        return rawequal(actual, expected)
    end
    if type(actual) == "table" and type(expected) == "table" then
        if #actual ~= #expected then return false end
        for i = 1, #actual do
            if not M.equal(actual[i], expected[i]) then return false end
        end
        return true
    end
    return actual == expected
end

-- Order-insensitive comparison for the unordered_equality kind: the two arrays
-- hold the same elements in any order. Defined in terms of `M.equal`, greedily
-- pairing each actual element with an as-yet-unused expected one — so it can
-- NEVER disagree with `equal`, because it IS `equal`, applied pairwise.
--
-- The previous version keyed each element through a string rendering and sorted
-- the keys, which was a second, weaker notion of equality living beside the real
-- one. It disagreed with `equal` in both directions: `{1}` vs `{1.0}` rendered
-- "1" vs "1.0" and failed while `equal(1, 1.0)` passed; and `{ {"a, b"} }` vs
-- `{ {"a", "b"} }` rendered alike (the comma-join) and passed while they are
-- plainly different. Keying only reached the top level, so nested tables were
-- worse still. Delegating to `equal` removes the whole second notion.
--
-- Greedy matching is exact here because `equal` is an equivalence relation
-- (exact value equality is transitive): if an actual element equals several
-- expected ones they are mutually equal, so consuming any is safe. O(n^2),
-- which is nothing at the sizes a generated case compares.
function M.unordered_equal(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        return false
    end
    if #actual ~= #expected then return false end
    local used = {}
    for i = 1, #actual do
        local matched = false
        for j = 1, #expected do
            if not used[j] and M.equal(actual[i], expected[j]) then
                used[j] = true
                matched = true
                break
            end
        end
        if not matched then return false end
    end
    return true
end

-- --- Per-student personalization primitives ---------------------------------
-- Mirror of chickadee_seed() in test_runtime.R and the Python equivalent. Lua
-- 5.4 has 64-bit integers but no bignum, so the 256-bit hex seed is folded with
-- Horner's method modulo 2^31-1 — the SAME reduction R uses, so a student's
-- seed is one number whatever language the assignment is in.

function M.seed()
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

-- The per-student grading inputs the worker materialized into _ck_inputs.lua
-- (a chunk returning a table), or an empty table when none were delivered.
-- The chunk is loaded with `chickadee` bound, because the values in it were
-- rendered by `JSONValue.luaLiteral`, which spells a JSON null inside a table
-- as the sentinel `chickadee.NULL` (Lua stores no `nil` in a constructor, so a
-- hole would silently eat an authored case's positional alignment).
--
-- Binding it HERE rather than making the file `require` the runtime itself
-- keeps `_ck_inputs.lua` a pure data chunk with no dependencies — which is what
-- lets the conformance matrix write one into an empty directory and read it
-- back. Without the binding a single null makes the chunk raise, `pcall`
-- swallows it, this returns `{}`, and every per-student value silently reads as
-- missing: a wrong mark rather than a crash.
function M.inputs()
    local env = setmetatable({ chickadee = M }, { __index = _G })
    local chunk = loadfile("_ck_inputs.lua", "t", env)
    if not chunk then return {} end
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then return value end
    return {}
end

-- --- Locating the student's submission --------------------------------------
-- Filenames Chickadee itself writes into the grading workspace are never the
-- student's submission.
local RESERVED = { ["test_runtime.lua"] = true, ["_ck_inputs.lua"] = true }

local function is_test_file(name)
    return name:match("^publictest") ~= nil
        or name:match("^releasetest") ~= nil
        or name:match("^secrettest") ~= nil
        or name:match("^studenttest") ~= nil
end

-- The student's submitted Lua file: solution.lua during validation, the
-- extracted notebook during grading.
--
-- Unlike R and Python, this reads ONLY the runner's `.chickadee_student_module`
-- hint, with `solution.lua` as the fallback. Lua's standard library cannot list
-- a directory — there is no `list.files` and no `os.listdir`, and `io.popen`
-- is a subprocess the wasm kernel does not have — so the scan those two fall
-- back to has no Lua equivalent. The hint is written by the runner on every
-- job, so this is the normal path rather than a degraded one.
function M.student_file()
    local hint = io.open(".chickadee_student_module", "r")
    if hint then
        local named = (hint:read("l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        hint:close()
        local base = named:match("([^/\\]+)$") or named
        if base:match("%.lua$") and not RESERVED[base] and not is_test_file(base)
            and base ~= running_script() then
            local exists = io.open(base, "r")
            if exists then
                exists:close()
                return base
            end
        end
    end
    local fallback = io.open("solution.lua", "r")
    if fallback then
        fallback:close()
        return "solution.lua"
    end
    return nil
end

-- Load the submission into a fresh environment, so the tests see exactly what
-- the student defined and nothing they defined can overwrite the harness.
--
-- Runtime errors are swallowed deliberately: a submission whose last top-level
-- line raises has still defined every function above it, and those are what the
-- tests are about. Compare test_runtime.R, which evaluates expression by
-- expression for the same reason.
function M.load_student()
    local file = M.student_file()
    if not file then
        M.errored("No Lua submission file was found to grade.")
    end
    local env = setmetatable({}, { __index = _G })
    local chunk, err = loadfile(file, "t", env)
    if not chunk then
        M.errored("Your submission (" .. file .. ") could not be parsed as Lua: " .. tostring(err))
    end
    pcall(chunk)
    return env
end

-- The submission split into notebook cells, for source-level checks.
--
-- `extractLua` writes an inert `-- ---- chickadee:cell N ----` comment ahead of
-- each cell, which is what gives a source-level check cell granularity that
-- plain concatenation loses. Same design as chickadee_student_cells in
-- test_runtime.R, down to the marker text — only the comment leader differs,
-- which is why both extractors share `extractWithCellMarkers`.
--
-- A submission that never came from a notebook (a hand-written .lua upload) has
-- no markers, so the whole file comes back as one cell — file granularity,
-- which is the honest answer for a file with no cells.
function M.student_cells()
    local file = M.student_file()
    if not file then
        M.errored("No Lua submission file was found to grade.")
    end
    local handle = io.open(file, "r")
    if not handle then return {} end
    local text = handle:read("a") or ""
    handle:close()

    -- Split without inventing a trailing empty line. Appending "\n" and
    -- matching greedily does invent one, which put a stray newline on the end
    -- of the LAST cell only — so a `cellContains` check comparing exact source
    -- would behave differently for the final cell than for every other one.
    local lines = {}
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = text:sub(pos, nl - 1)
            pos = nl + 1
        else
            lines[#lines + 1] = text:sub(pos)
            pos = #text + 1
        end
    end

    local cells, current, seen_marker = {}, nil, false
    for _, line in ipairs(lines) do
        if line:match("^%-%- ---- chickadee:cell %d+ ----$") then
            if current then cells[#cells + 1] = table.concat(current, "\n") end
            current, seen_marker = {}, true
        elseif current then
            current[#current + 1] = line
        end
    end
    if current then cells[#cells + 1] = table.concat(current, "\n") end
    if not seen_marker then return { (text:gsub("\n$", "")) } end
    return cells
end

-- Fetch a function the student was asked to write; a clear error when it is
-- missing or was bound to something that is not a function.
function M.require_fn(env, name)
    local value = rawget(env, name)
    if type(value) ~= "function" then
        M.errored(string.format("Your submission must define a function called `%s()`.", name))
    end
    return value
end

return M

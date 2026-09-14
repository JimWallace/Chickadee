-- Test: io
-- Generated from pattern family "Family" [fam] spec_hash=eb00ef813bc014b0 — edit the family, not this file.
local chickadee = require("test_runtime")

local stdin_text = "3\n4\n"
local expected = "7"

local file = chickadee.student_file()
if not file then
    chickadee.errored("No Lua submission file was found to run.")
end

local function ck_normalize(text)
    local lines = {}
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("%s+$", ""))
    end
    while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
    end
    return table.concat(lines, "\n")
end

local ck_pos = 1
local function ck_read_line(keep_newline)
    if ck_pos > #stdin_text then return nil end
    local nl = stdin_text:find("\n", ck_pos, true)
    local line
    if nl then
        line = stdin_text:sub(ck_pos, keep_newline and nl or nl - 1)
        ck_pos = nl + 1
    else
        line = stdin_text:sub(ck_pos)
        ck_pos = #stdin_text + 1
    end
    return line
end
local function ck_read_one(fmt)
    if fmt == nil then return ck_read_line(false) end
    if type(fmt) == "number" then
        if ck_pos > #stdin_text then return nil end
        local s = stdin_text:sub(ck_pos, ck_pos + fmt - 1)
        ck_pos = ck_pos + fmt
        return s
    end
    fmt = tostring(fmt):gsub("^%*", "")
    if fmt == "n" then
        local rest = stdin_text:sub(ck_pos)
        local _, e, num = rest:find("^%s*([%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*)")
        if not num then return nil end
        ck_pos = ck_pos + e
        return tonumber(num)
    elseif fmt == "a" then
        local s = stdin_text:sub(ck_pos)
        ck_pos = #stdin_text + 1
        return s
    elseif fmt == "L" then
        return ck_read_line(true)
    end
    return ck_read_line(false)
end

local captured = {}
local ck_stdout = {}
function ck_stdout.write(...)
    local n = select("#", ...)
    local start = (n >= 1 and select(1, ...) == ck_stdout) and 2 or 1
    for i = start, n do
        captured[#captured + 1] = tostring((select(i, ...)))
    end
    return ck_stdout
end
local ck_stdin = {}
function ck_stdin.read(...)
    local n = select("#", ...)
    local start = (n >= 1 and select(1, ...) == ck_stdin) and 2 or 1
    if n < start then return ck_read_one(nil) end
    local results = {}
    for i = start, n do
        results[#results + 1] = ck_read_one((select(i, ...)))
    end
    return table.unpack(results, 1, n - start + 1)
end
function ck_stdin.lines(...)
    return function() return ck_read_line(false) end
end

local env = setmetatable({}, { __index = _G })
env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    captured[#captured + 1] = table.concat(parts, "\t") .. "\n"
end
env.io = setmetatable({
    write = ck_stdout.write,
    read = ck_stdin.read,
    lines = function(name, ...)
        if name == nil then return ck_stdin.lines() end
        return io.lines(name, ...)
    end,
    stdout = ck_stdout,
    stdin = ck_stdin,
}, { __index = io })
env.os = setmetatable({ exit = function() error("chickadee:exit", 0) end }, { __index = os })

local chunk, load_err = loadfile(file, "t", env)
if not chunk then
    chickadee.failed("Your submission (" .. file .. ") could not be parsed as Lua: " .. tostring(load_err))
end
local ran, run_err = pcall(chunk)
local actual_output = table.concat(captured)

if not ran and tostring(run_err) ~= "chickadee:exit" then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", chickadee.format(stdin_text), "\n",
        "  got:      ", chickadee.format(ck_normalize(actual_output)), "\n",
        "  error:    ", tostring(run_err),
    }))
end

local ok = ck_normalize(actual_output) == ck_normalize(expected)
if not ok then
    chickadee.failed(table.concat({
        "wrong output\n",
        "  input:    ", chickadee.format(stdin_text), "\n",
        "  expected: ", chickadee.format(expected), "\n",
        "  got:      ", chickadee.format(ck_normalize(actual_output)),
    }))
end

chickadee.passed("Printed the expected output")
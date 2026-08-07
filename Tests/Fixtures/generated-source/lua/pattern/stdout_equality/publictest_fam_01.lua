-- Test: s
-- Generated from pattern family "Family" [fam] spec_hash=fc8371b5e923b61d — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 1

local expected_output = "hello"

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

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

local captured = {}
student.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    captured[#captured + 1] = table.concat(parts, "\t") .. "\n"
end
student.io = setmetatable(
    { write = function(...)
        for i = 1, select("#", ...) do
            captured[#captured + 1] = tostring((select(i, ...)))
        end
    end },
    { __index = io })

local ok, result = pcall(target, x)
student.print = nil
student.io = nil

if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  error:    ", tostring(result),
    }))
end

local actual_output = table.concat(captured)
if ck_normalize(actual_output) ~= ck_normalize(expected_output) then
    chickadee.failed(table.concat({
        "wrong output\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", chickadee.format(ck_normalize(expected_output)), "\n",
        "  got:      ", chickadee.format(ck_normalize(actual_output)),
    }))
end

chickadee.passed("Printed the expected output")
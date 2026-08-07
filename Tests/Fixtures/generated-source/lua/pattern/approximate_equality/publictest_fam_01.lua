-- Test: b
-- Generated from pattern family "Family" [fam] spec_hash=8fff023f74a1087a — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 18.49

local expected = 1
local tolerance = 1e-06

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local ok, result = pcall(target, x)
if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", chickadee.format(expected), " (±", tostring(tolerance), ")\n",
        "  error:    ", tostring(result),
    }))
end

if type(result) ~= "number" then
    chickadee.failed(table.concat({
        "wrong return type\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: a single number close to ", chickadee.format(expected), "\n",
        "  got:      ", chickadee.format(result),
    }))
end

local delta = math.abs(result - expected)
if delta > tolerance then
    chickadee.failed(table.concat({
        "value outside tolerance\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", chickadee.format(expected), " (±", tostring(tolerance), ")\n",
        "  got:      ", chickadee.format(result), "\n",
        "  delta:    ", chickadee.format(delta),
    }))
end

chickadee.passed("Returned " .. chickadee.format(result) .. " (within ±" .. tostring(tolerance) .. ")")
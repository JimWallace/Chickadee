-- Test: p
-- Generated from pattern family "Family" [fam] spec_hash=373c736715269bba — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 1

local budget_ms = 0.5

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local started = os.clock()
local ok, result = pcall(target, x)
local elapsed_ms = (os.clock() - started) * 1000.0

if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  error:    ", tostring(result),
    }))
end

if elapsed_ms > budget_ms then
    chickadee.failed(table.concat({
        "too slow\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  budget:   ", string.format("%.1f", budget_ms), " ms\n",
        "  took:     ", string.format("%.1f", elapsed_ms), " ms\n",
        "  Hint: look for repeated work that could be done once.",
    }))
end

chickadee.passed("Completed in " .. string.format("%.1f", elapsed_ms)
    .. " ms (budget " .. string.format("%.1f", budget_ms) .. " ms)")
-- Test: b
-- Generated from pattern family "Family" [fam] spec_hash=567149c178ff72bc — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 18.49

local expected = 1

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local ok, result = pcall(target, x)
if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", chickadee.format(expected), "\n",
        "  error:    ", tostring(result),
    }))
end

if not chickadee.equal(result, expected) then
    chickadee.failed(table.concat({
        "wrong value\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", chickadee.format(expected), "\n",
        "  got:      ", chickadee.format(result),
    }))
end

chickadee.passed("Returned " .. chickadee.format(result))
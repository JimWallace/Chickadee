-- Test: u
-- Generated from pattern family "Family" [fam] spec_hash=742f48b545094cfb — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 1

local expected = {1, 2}

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local ok, result = pcall(target, x)
if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: the same elements as ", chickadee.format(expected), "\n",
        "  error:    ", tostring(result),
    }))
end

if not chickadee.unordered_equal(result, expected) then
    chickadee.failed(table.concat({
        "wrong elements\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: the same elements as ", chickadee.format(expected), "\n",
        "  got:      ", chickadee.format(result),
    }))
end

chickadee.passed("Returned " .. chickadee.format(result))
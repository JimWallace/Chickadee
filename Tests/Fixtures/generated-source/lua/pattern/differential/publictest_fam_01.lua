-- Test: d
-- Generated from pattern family "Family" [fam] spec_hash=1741948f521351f2 — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 18.49


-- Instructor's reference implementation, rendered verbatim.
function ck_ref_classify(x)
    return 1
end

local ref_ok, expected = pcall(ck_ref_classify, x)
if not ref_ok then
    chickadee.errored(table.concat({
        "the reference implementation raised\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  error:    ", tostring(expected),
    }))
end

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
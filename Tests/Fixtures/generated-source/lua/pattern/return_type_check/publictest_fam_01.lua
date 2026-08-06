-- Test: t
-- Generated from pattern family "Family" [fam] spec_hash=8adb8f0c701a46e7 — edit the family, not this file.
local chickadee = require("test_runtime")

local x = 1

local expected_type_name = "int"

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local ok, result = pcall(target, x)
if not ok then
    chickadee.failed(table.concat({
        "unexpected exception\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: a ", expected_type_name, " return value\n",
        "  error:    ", tostring(result),
    }))
end

if not (math.type(result) == "integer") then
    chickadee.failed(table.concat({
        "wrong return type\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  expected: ", expected_type_name, "\n",
        "  got:      ", type(result), " (value: ", chickadee.format(result), ")",
    }))
end

chickadee.passed("Returned a " .. type(result))
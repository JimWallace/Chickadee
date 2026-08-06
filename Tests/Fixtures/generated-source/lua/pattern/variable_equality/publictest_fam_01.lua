-- Test: v
-- Generated from pattern family "Family" [fam] spec_hash=3e7d072c983cd304 — edit the family, not this file.
local chickadee = require("test_runtime")

local variable_name = "total"
local expected = 3

local student = chickadee.load_student()
local actual = rawget(student, variable_name)

if actual == nil then
    chickadee.failed(table.concat({
        "Variable `", variable_name, "` is not defined\n",
        "  expected: ", chickadee.format(expected),
    }))
end

if not chickadee.equal(actual, expected) then
    chickadee.failed(table.concat({
        "Variable `", variable_name, "` has the wrong value\n",
        "  expected: ", chickadee.format(expected), "\n",
        "  got:      ", chickadee.format(actual),
    }))
end

chickadee.passed(variable_name .. " == " .. chickadee.format(actual))
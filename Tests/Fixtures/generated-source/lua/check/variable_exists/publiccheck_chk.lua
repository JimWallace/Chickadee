-- Test: Check
-- Generated from notebook check [chk] spec_hash=1198d01d1fe85b02 — edit the check, not this file.
local chickadee = require("test_runtime")

local variable_name = "df"

local student = chickadee.load_student()
local actual = rawget(student, variable_name)

if actual == nil then
    chickadee.failed("Variable `" .. variable_name .. "` is not defined in your notebook.")
end

chickadee.passed("`" .. variable_name .. "` is defined")
-- Test: Check
-- Generated from notebook check [chk] spec_hash=d40c23d7908c1bd9 — edit the check, not this file.
local chickadee = require("test_runtime")

local function_name = "df"

local student = chickadee.load_student()
local target = rawget(student, function_name)

if target == nil then
    chickadee.failed("`" .. function_name .. "` is not defined — define a function named `"
        .. function_name .. "()` in your notebook.")
end
if type(target) ~= "function" then
    chickadee.failed("`" .. function_name .. "` is defined but is not a function (got "
        .. type(target) .. ").")
end

chickadee.passed("`" .. function_name .. "` is defined")
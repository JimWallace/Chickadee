-- Test: Check
-- Generated from notebook check [chk] spec_hash=1ea518a2321aaf7a — edit the check, not this file.
local chickadee = require("test_runtime")

local variable_name = "df"
local expected = {}
local rtol = 1e-07
local atol = 0.0

local student = chickadee.load_student()
local actual = rawget(student, variable_name)

if actual == nil then
    chickadee.failed("Variable `" .. variable_name .. "` is not defined in your notebook.")
end
if type(actual) ~= "table" then
    chickadee.failed(table.concat({
        "Variable `", variable_name, "` could not be read as a sequence of numbers.\n",
        "  got:      ", type(actual),
    }))
end
if #actual ~= #expected then
    chickadee.failed(table.concat({
        "Variable `", variable_name, "` has the wrong length.\n",
        "  expected: ", tostring(#expected), " values\n",
        "  got:      ", tostring(#actual), " values",
    }))
end

-- Mirrors numpy's allclose, including its equal_nan default: two NaNs
-- agree, and two infinities of the same sign agree. Non-finite
-- positions are settled by those two rules alone and never by the
-- tolerance — `rtol * inf` is `inf`, which would otherwise make every
-- infinity match every other one.
--
-- Lua spells the two tests without library help: NaN is the only value
-- that is not equal to itself, and the infinities are exactly
-- `math.huge` and its negation.
local function is_nan(x) return x ~= x end
local function is_inf(x) return x == math.huge or x == -math.huge end

for i = 1, #expected do
    local a, e = actual[i], expected[i]
    if type(a) ~= "number" then
        chickadee.failed(table.concat({
            "Variable `", variable_name, "` contains a value that is not a number.\n",
            "  position: ", tostring(i), "\n",
            "  got:      ", chickadee.format(a),
        }))
    end
    local ok
    if is_nan(a) or is_nan(e) then
        ok = is_nan(a) and is_nan(e)
    elseif is_inf(a) or is_inf(e) then
        ok = is_inf(a) and is_inf(e) and ((a > 0) == (e > 0))
    else
        ok = math.abs(a - e) <= (atol + rtol * math.abs(e))
    end
    if not ok then
        chickadee.failed(table.concat({
            "Variable `", variable_name, "` is not close enough to expected.\n",
            "  position: ", tostring(i), "\n",
            "  expected: ", chickadee.format(e), "\n",
            "  got:      ", chickadee.format(a),
        }))
    end
end

chickadee.passed("`" .. variable_name .. "` matches all " .. tostring(#expected) .. " expected value(s)")
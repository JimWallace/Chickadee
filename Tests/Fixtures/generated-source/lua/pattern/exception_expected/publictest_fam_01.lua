-- Test: e
-- Generated from pattern family "Family" [fam] spec_hash=af181e8a5562a736 — edit the family, not this file.
local chickadee = require("test_runtime")

local x = -1

local student = chickadee.load_student()
local target = chickadee.require_fn(student, "classify")

local ok, err = pcall(target, x)

if ok then
    chickadee.failed(table.concat({
        "expected an error, but the call succeeded\n",
        "  input:    ", "x=", chickadee.format(x), "\n",
        "  got:      ", chickadee.format(err),
    }))
end

    local wanted = "ValueError"
    local raised_text = tostring(err)
    if not string.find(string.lower(raised_text), string.lower(wanted), 1, true) then
        chickadee.failed(table.concat({
            "wrong error raised\n",
            "  input:    ", "x=", chickadee.format(x), "\n",
            "  expected: an error matching ", wanted, "\n",
            "  got:      ", raised_text,
        }))
    end

chickadee.passed("Raised an error as expected")
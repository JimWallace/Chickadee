-- Test: Check
-- Generated from notebook check [chk] spec_hash=3933c523f64e655d — edit the check, not this file.
local chickadee = require("test_runtime")

local needle = ""

local cells = chickadee.student_cells()
local matched = {}
for _, cell in ipairs(cells) do
    -- The trailing `true` is plain-find: metacharacters in the
    -- instructor's text are matched literally, never interpreted.
    if string.find(cell, needle, 1, true) then
        matched[#matched + 1] = cell
    end
end

if #matched == 0 then
    chickadee.failed(table.concat({
        "No code cell in your notebook matches `", needle, "`.\n",
        "  expected: at least one cell containing the pattern\n",
        "  searched: ", tostring(#cells), " code cell(s)",
    }))
end

-- (no must-differ-from constraint)

chickadee.passed("Found " .. tostring(#matched) .. " cell(s) containing `" .. needle .. "`")
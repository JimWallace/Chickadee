% Test: Check
% Generated from notebook check [chk] spec_hash=3933c523f64e655d — edit the check, not this file.
chickadee = test_runtime();

needle = "";

% Whitespace-normalize both sides of the must-differ comparison, so
% trailing newlines or a re-indent don't disguise a copy of the example.
function out = ck_ws_normalize(s)
    out = strtrim(regexprep(s, '\s+', " "));
end

cells = chickadee.student_cells();
matched = {};
for i = 1:numel(cells)
    cell_text = cells{i};
    if !isempty(strfind(cell_text, needle))
        matched{end + 1} = cell_text;
    end
end

if isempty(matched)
    chickadee.failed(["No code cell in your notebook matches `" needle "`.\n" ...
        "  expected: at least one cell containing the pattern\n" ...
        "  searched: " num2str(numel(cells)) " code cell(s)"]);
end

% (no must-differ-from constraint)

chickadee.passed(["Found " num2str(numel(matched)) " cell(s) containing `" needle "`"]);
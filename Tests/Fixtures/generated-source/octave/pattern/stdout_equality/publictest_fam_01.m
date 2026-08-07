% Test: s
% Generated from pattern family "Family" [fam] spec_hash=fc8371b5e923b61d — edit the family, not this file.
chickadee = test_runtime();

x = 1;

expected_output = "hello";

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

function out = ck_normalize(text)
    lines = strsplit(text, sprintf("\n"), "CollapseDelimiters", false);
    for i = 1:numel(lines)
        lines{i} = regexprep(lines{i}, '\s+$', "");
    end
    while !isempty(lines) && isempty(lines{end})
        lines(end) = [];
    end
    out = strjoin(lines, sprintf("\n"));
end

try
    captured = evalc("target(x);");
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  error:    " err.message]);
end

if !strcmp(ck_normalize(captured), ck_normalize(expected_output))
    chickadee.failed(["wrong output\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " chickadee.format(ck_normalize(expected_output)) "\n" ...
        "  got:      " chickadee.format(ck_normalize(captured))]);
end

chickadee.passed("Printed the expected output");
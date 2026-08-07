% Test: b
% Generated from pattern family "Family" [fam] spec_hash=567149c178ff72bc — edit the family, not this file.
chickadee = test_runtime();

x = 18.49;

expected = 1;

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

try
    result = target(x);
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " chickadee.format(expected) "\n" ...
        "  error:    " err.message]);
end

if !chickadee.equal(result, expected)
    chickadee.failed(["wrong value\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " chickadee.format(expected) "\n" ...
        "  got:      " chickadee.format(result)]);
end

chickadee.passed(["Returned " chickadee.format(result)]);
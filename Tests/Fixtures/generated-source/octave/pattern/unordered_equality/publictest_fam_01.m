% Test: u
% Generated from pattern family "Family" [fam] spec_hash=742f48b545094cfb — edit the family, not this file.
chickadee = test_runtime();

x = 1;

expected = [1, 2];

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

try
    result = target(x);
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: the same elements as " chickadee.format(expected) "\n" ...
        "  error:    " err.message]);
end

if !chickadee.unordered_equal(result, expected)
    chickadee.failed(["wrong elements\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: the same elements as " chickadee.format(expected) "\n" ...
        "  got:      " chickadee.format(result)]);
end

chickadee.passed(["Returned " chickadee.format(result)]);
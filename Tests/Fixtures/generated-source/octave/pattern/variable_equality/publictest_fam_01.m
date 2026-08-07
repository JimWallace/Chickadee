% Test: v
% Generated from pattern family "Family" [fam] spec_hash=3e7d072c983cd304 — edit the family, not this file.
chickadee = test_runtime();

variable_name = "total";
expected = 3;

student = chickadee.load_student();

if !chickadee.has_var(student, variable_name)
    chickadee.failed(["Variable `" variable_name "` is not defined\n" ...
        "  expected: " chickadee.format(expected)]);
end
actual = chickadee.get_var(student, variable_name);

if !chickadee.equal(actual, expected)
    chickadee.failed(["Variable `" variable_name "` has the wrong value\n" ...
        "  expected: " chickadee.format(expected) "\n" ...
        "  got:      " chickadee.format(actual)]);
end

chickadee.passed([variable_name " == " chickadee.format(actual)]);
% Test: t
% Generated from pattern family "Family" [fam] spec_hash=8adb8f0c701a46e7 — edit the family, not this file.
chickadee = test_runtime();

x = 1;

expected_type_name = "int";

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

try
    result = target(x);
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: a " expected_type_name " return value\n" ...
        "  error:    " err.message]);
end

if !(isnumeric(result))
    chickadee.failed(["wrong return type\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " expected_type_name "\n" ...
        "  got:      " class(result) " (value: " chickadee.format(result) ")"]);
end

chickadee.passed(["Returned a " class(result)]);
% Test: b
% Generated from pattern family "Family" [fam] spec_hash=8fff023f74a1087a — edit the family, not this file.
chickadee = test_runtime();

x = 18.49;

expected = 1;
tolerance = 1e-06;

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

try
    result = target(x);
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " chickadee.format(expected) " (±" num2str(tolerance) ")\n" ...
        "  error:    " err.message]);
end

if !isnumeric(result) || !isscalar(result)
    chickadee.failed(["wrong return type\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: a single number close to " chickadee.format(expected) "\n" ...
        "  got:      " chickadee.format(result)]);
end

delta = abs(result - expected);
if delta > tolerance
    chickadee.failed(["value outside tolerance\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  expected: " chickadee.format(expected) " (±" num2str(tolerance) ")\n" ...
        "  got:      " chickadee.format(result) "\n" ...
        "  delta:    " chickadee.format(delta)]);
end

chickadee.passed(["Returned " chickadee.format(result) " (within ±" num2str(tolerance) ")"]);
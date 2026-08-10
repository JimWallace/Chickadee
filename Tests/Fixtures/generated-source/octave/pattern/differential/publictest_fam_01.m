% Test: d
% Generated from pattern family "Family" [fam] spec_hash=e84b72fc79ab8a7c — edit the family, not this file.
chickadee = test_runtime();

x = 18.49;


% Instructor's reference implementation, rendered verbatim.
function r = ck_ref_classify(x)
  r = 1;
end

try
    expected = ck_ref_classify(x);
catch err
    chickadee.errored(["the reference implementation raised\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  error:    " err.message]);
end

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
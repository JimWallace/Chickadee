% Test: p
% Generated from pattern family "Family" [fam] spec_hash=373c736715269bba — edit the family, not this file.
chickadee = test_runtime();

x = 1;

budget_ms = 0.5;

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

started = tic();
try
    result = target(x);
catch err
    chickadee.failed(["unexpected exception\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  error:    " err.message]);
end
elapsed_ms = toc(started) * 1000;

if elapsed_ms > budget_ms
    chickadee.failed(["too slow\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  budget:   " num2str(budget_ms) " ms\n" ...
        "  took:     " num2str(round(elapsed_ms * 10) / 10) " ms\n" ...
        "  Hint: look for repeated work that could be done once."]);
end

chickadee.passed(["Completed in " num2str(round(elapsed_ms * 10) / 10) ...
    " ms (budget " num2str(budget_ms) " ms)"]);
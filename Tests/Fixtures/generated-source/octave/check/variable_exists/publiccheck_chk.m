% Test: Check
% Generated from notebook check [chk] spec_hash=1198d01d1fe85b02 — edit the check, not this file.
chickadee = test_runtime();

variable_name = "df";

student = chickadee.load_student();

if !chickadee.has_var(student, variable_name)
    chickadee.failed(["Variable `" variable_name "` is not defined in your notebook."]);
end
actual = chickadee.get_var(student, variable_name);

chickadee.passed(["`" variable_name "` is defined"]);
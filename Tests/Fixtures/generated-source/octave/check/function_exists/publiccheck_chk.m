% Test: Check
% Generated from notebook check [chk] spec_hash=d40c23d7908c1bd9 — edit the check, not this file.
chickadee = test_runtime();

function_name = "df";

student = chickadee.load_student();
target = chickadee.require_fn(student, function_name);

chickadee.passed(["`" function_name "` is defined"]);
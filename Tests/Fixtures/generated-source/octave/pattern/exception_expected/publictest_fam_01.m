% Test: e
% Generated from pattern family "Family" [fam] spec_hash=af181e8a5562a736 — edit the family, not this file.
chickadee = test_runtime();

x = -1;

student = chickadee.load_student();
target = chickadee.require_fn(student, "classify");

caught = [];
try
    result = target(x);
catch err
    caught = err;
end

if isempty(caught)
    chickadee.failed(["expected an error, but the call succeeded\n" ...
        "  input:    " "x=" chickadee.format(x) "\n" ...
        "  got:      " chickadee.format(result)]);
end

    wanted = "ValueError";
    hit = !isempty(strfind(lower(caught.identifier), lower(wanted))) ...
        || !isempty(strfind(lower(caught.message), lower(wanted)));
    if !hit
        chickadee.failed(["wrong error raised\n" ...
            "  input:    " "x=" chickadee.format(x) "\n" ...
            "  expected: an error matching " wanted "\n" ...
            "  got:      " caught.identifier ": " caught.message]);
    end

chickadee.passed(["Raised an error as expected (" caught.message ")"]);
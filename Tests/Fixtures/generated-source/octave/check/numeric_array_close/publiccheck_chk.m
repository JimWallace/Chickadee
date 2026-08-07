% Test: Check
% Generated from notebook check [chk] spec_hash=1ea518a2321aaf7a — edit the check, not this file.
chickadee = test_runtime();

variable_name = "df";
expected = [];
rtol = 1e-07;
atol = 0.0;

student = chickadee.load_student();

if !chickadee.has_var(student, variable_name)
    chickadee.failed(["Variable `" variable_name "` is not defined in your notebook."]);
end
actual = chickadee.get_var(student, variable_name);

if !isnumeric(actual) && !islogical(actual)
    chickadee.failed(["Variable `" variable_name "` could not be read as a sequence of numbers.\n" ...
        "  got:      " class(actual)]);
end
if numel(actual) != numel(expected)
    chickadee.failed(["Variable `" variable_name "` has the wrong length.\n" ...
        "  expected: " num2str(numel(expected)) " values\n" ...
        "  got:      " num2str(numel(actual)) " values"]);
end

% Mirrors numpy's allclose, including its equal_nan default: two NaNs
% agree, and two infinities of the same sign agree. Non-finite
% positions are settled by those two rules alone and never by the
% tolerance — `rtol * Inf` is `Inf`, which would otherwise make every
% infinity match every other one.
flat_actual = double(actual(:));
flat_expected = expected(:);
for i = 1:numel(flat_expected)
    a = flat_actual(i);
    e = flat_expected(i);
    if isnan(a) || isnan(e)
        ok = isnan(a) && isnan(e);
    elseif isinf(a) || isinf(e)
        ok = isinf(a) && isinf(e) && (sign(a) == sign(e));
    else
        ok = abs(a - e) <= (atol + rtol * abs(e));
    end
    if !ok
        chickadee.failed(["Variable `" variable_name "` is not close enough to expected.\n" ...
            "  position: " num2str(i) "\n" ...
            "  expected: " chickadee.format(e) "\n" ...
            "  got:      " chickadee.format(a)]);
    end
end

chickadee.passed(["`" variable_name "` matches all " num2str(numel(expected)) " expected value(s)"]);
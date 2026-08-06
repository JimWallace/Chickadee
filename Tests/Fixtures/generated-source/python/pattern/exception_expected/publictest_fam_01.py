# Test: e
# Generated from pattern family "Family" [fam] spec_hash=af181e8a5562a736 — edit the family, not this file.

x = -1
expected_exception_name = "ValueError"

raised = None
result = None
try:
    result = student_module.classify(x)
except BaseException as ex:
    raised = ex

if raised is None:
    failed(
        "expected exception was not raised\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected_exception_name}\n"
        f"  got:      no exception (returned {result!r})\n"            )

# Match by class-name MRO walk so the test doesn't need to import
# the user's exception class in this scope.  Any class in the
# raised exception's __mro__ with __name__ == expected_exception_name
# counts as a match — gives `ValueError` matching when the student
# raises a subclass too.
raised_chain = [getattr(b, "__name__", "") for b in type(raised).__mro__]
if expected_exception_name not in raised_chain:
    failed(
        "wrong exception type\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected_exception_name}\n"
        f"  got:      {type(raised).__name__}: {raised}\n"            )

passed(f"Raised {type(raised).__name__} as expected")
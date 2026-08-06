# Test: Check
# Generated from notebook check "chk" kind=numeric_array_close spec_hash=1ea518a2321aaf7a — edit the check, not this file.

import numpy as np
import test_runtime as _tr

variable_name = "df"
expected = np.array([], dtype=float)

# Runtime-state check: read the notebook AS EXECUTED (an array is
# built by function calls, which the extractor quarantines at import).
_MISSING = object()
actual_obj = getattr(_tr.student_main_state(), variable_name, _MISSING)
if actual_obj is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined in the student notebook.\n"
        f"  expected an array of length {len(expected)}\n"
    )

try:
    actual = np.asarray(actual_obj, dtype=float)
except Exception as ex:
    failed(
        f"Variable `{variable_name}` could not be coerced to a numeric array.\n"
        f"  got: {type(actual_obj).__name__}\n"
        f"  error: {type(ex).__name__}: {ex}\n"
    )

if actual.shape != expected.shape:
    failed(
        f"Variable `{variable_name}` has the wrong shape.\n"
        f"  expected: {expected.shape}\n"
        f"  got:      {actual.shape}\n"
    )

try:
    np.testing.assert_allclose(
        actual,
        expected
    )
except AssertionError as ex:
    failed(
        f"Variable `{variable_name}` is not close enough to expected.\n"
        f"\n{ex}"
    )

passed(f"`{variable_name}` is close to expected (length {len(expected)})")
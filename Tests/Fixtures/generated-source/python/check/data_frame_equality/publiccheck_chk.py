# Test: Check
# Generated from notebook check "chk" kind=data_frame_equality spec_hash=b7b2276e1ec7ff12 — edit the check, not this file.

import pandas as pd
import test_runtime as _tr

variable_name = "df"

try:
    expected = pd.read_csv("_expected_chk.csv")
except Exception as ex:
    errored(f"Could not load expected DataFrame from _expected_chk.csv: {ex}")

# Runtime-state check: read the notebook AS EXECUTED (a DataFrame is
# built by function calls, which the extractor quarantines at import).
_MISSING = object()
actual = getattr(_tr.student_main_state(), variable_name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined in the student notebook.\n"
        f"  expected a DataFrame with shape {expected.shape} and columns {list(expected.columns)}\n"
    )

if not isinstance(actual, pd.DataFrame):
    failed(
        f"Variable `{variable_name}` is not a DataFrame.\n"
        f"  expected: a DataFrame with shape {expected.shape}\n"
        f"  got:      {type(actual).__name__}\n"
    )

actual_cmp = actual.reset_index(drop=True)
expected_cmp = expected.reset_index(drop=True)

try:
    pd.testing.assert_frame_equal(
        actual_cmp,
        expected_cmp,
        check_dtype=True,
            check_like=False
    )
except AssertionError as ex:
    # pandas' assert_frame_equal raises with a useful diff in `ex`.
    # Surface it directly along with shape/column context so the
    # student can see the structural mismatch at a glance.
    failed(
        f"Variable `{variable_name}` does not match expected.\n"
        f"  expected shape: {expected.shape}\n"
        f"  got shape:      {actual.shape}\n"
        f"  expected cols:  {list(expected.columns)}\n"
        f"  got cols:       {list(actual.columns)}\n"
        f"\n{ex}"
    )

passed(f"`{variable_name}` matches expected DataFrame")
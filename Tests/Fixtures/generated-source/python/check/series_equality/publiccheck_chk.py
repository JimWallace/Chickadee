# Test: Check
# Generated from notebook check "chk" kind=series_equality spec_hash=24c7f42fa3c4155d — edit the check, not this file.

import pandas as pd
import test_runtime as _tr

variable_name = "df"

try:
    # Single-column CSV → Series via squeeze().  Falls back to the
    # first column if pandas returns a DataFrame (multi-column CSV
    # is rejected by the validator at save time).
    _expected_frame = pd.read_csv("_expected_chk.csv")
    expected = _expected_frame.squeeze("columns")
    if not isinstance(expected, pd.Series):
        expected = _expected_frame.iloc[:, 0]
except Exception as ex:
    errored(f"Could not load expected Series from _expected_chk.csv: {ex}")

# Runtime-state check: read the notebook AS EXECUTED (a Series is
# built by function calls, which the extractor quarantines at import).
_MISSING = object()
actual = getattr(_tr.student_main_state(), variable_name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined in the student notebook.\n"
        f"  expected a Series of length {len(expected)}\n"
    )

if not isinstance(actual, pd.Series):
    failed(
        f"Variable `{variable_name}` is not a Series.\n"
        f"  expected: a Series of length {len(expected)}\n"
        f"  got:      {type(actual).__name__}\n"
    )

actual_cmp = actual.reset_index(drop=True)
expected_cmp = expected.reset_index(drop=True)

try:
    pd.testing.assert_series_equal(
        actual_cmp,
        expected_cmp,
        check_dtype=True
    )
except AssertionError as ex:
    failed(
        f"Variable `{variable_name}` does not match expected Series.\n"
        f"  expected length: {len(expected)}\n"
        f"  got length:      {len(actual)}\n"
        f"\n{ex}"
    )

passed(f"`{variable_name}` matches expected Series")
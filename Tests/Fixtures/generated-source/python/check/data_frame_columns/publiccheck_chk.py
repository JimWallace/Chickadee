# Test: Check
# Generated from notebook check "chk" kind=data_frame_columns spec_hash=099de8998944375d — edit the check, not this file.

import test_runtime as _tr

variable_name = "df"
expected_columns = ["a", "b"]

# Runtime-state check: read the notebook AS EXECUTED (a DataFrame is
# built by function calls, which the extractor quarantines at import).
_MISSING = object()
actual = getattr(_tr.student_main_state(), variable_name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined in the student notebook.\n"
        f"  expected columns: {expected_columns}\n"
    )

actual_columns = getattr(actual, "columns", None)
if actual_columns is None:
    failed(
        f"Variable `{variable_name}` is not a DataFrame (no .columns attribute).\n"
        f"  expected columns: {expected_columns}\n"
        f"  got:              {type(actual).__name__}\n"
    )

if list(actual_columns) != expected_columns:
    failed(
        f"Variable `{variable_name}` has the wrong columns (exact match required).\n"
        f"  expected: {expected_columns}\n"
        f"  got:      {list(actual_columns)}\n"
    )

passed(f"`{variable_name}` columns match exactly")
# Test: Check
# Generated from notebook check "chk" kind=data_frame_shape spec_hash=754da7a2a0fa49ee — edit the check, not this file.

import test_runtime as _tr

variable_name = "df"
expected_shape = (3, 2)

# Runtime-state check: read the notebook AS EXECUTED (a DataFrame is
# built by function calls, which the extractor quarantines at import).
_MISSING = object()
actual = getattr(_tr.student_main_state(), variable_name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined in the student notebook.\n"
        f"  expected: a DataFrame with shape {expected_shape}\n"
    )

shape = getattr(actual, "shape", None)
if shape is None:
    failed(
        f"Variable `{variable_name}` is not a DataFrame.\n"
        f"  expected: a DataFrame with shape {expected_shape}\n"
        f"  got:      {type(actual).__name__}\n"
    )

try:
    actual_shape = tuple(int(d) for d in shape)
except Exception:
    failed(
        f"Variable `{variable_name}` has an unreadable shape `{shape!r}`.\n"
        f"  expected: a DataFrame with shape {expected_shape}\n"
    )

if actual_shape != expected_shape:
    failed(
        f"Variable `{variable_name}` has the wrong shape.\n"
        f"  expected: {expected_shape}\n"
        f"  got:      {actual_shape}\n"
    )

passed(f"`{variable_name}` has shape {actual_shape}")
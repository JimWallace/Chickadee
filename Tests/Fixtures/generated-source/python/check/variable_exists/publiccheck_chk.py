# Test: Check
# Generated from notebook check "chk" kind=variable_exists spec_hash=1198d01d1fe85b02 — edit the check, not this file.

import test_runtime as _tr

name = "df"

# Runtime-state check: read the notebook AS EXECUTED (the extractor
# quarantines side-effecting top-level statements out of plain imports,
# so `x = compute(...)` is only defined in main-mode state).
_MISSING = object()
actual = getattr(_tr.student_main_state(), name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{name}` is not defined in the student notebook.\n"
        f"  expected: a module-level variable named `{name}`\n"
    )

# (no type check; existence only)

passed(f"`{name}` is defined")
# Test: Check
# Generated from notebook check "chk" kind=function_exists spec_hash=d40c23d7908c1bd9 — edit the check, not this file.

import inspect

name = "df"

_MISSING = object()
fn = getattr(student_module, name, _MISSING)
if fn is _MISSING:
    failed(
        f"`{name}` is not defined in the student notebook.\n"
        f"  expected: a callable named `{name}`\n"
    )

if not callable(fn):
    failed(
        f"`{name}` is defined but not callable.\n"
        f"  got: {type(fn).__name__}\n"
    )

# (no arity check; existence + callability only)

passed(f"`{name}` is defined and callable")
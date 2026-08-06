# Test: v
# Generated from pattern family "Family" [fam] spec_hash=3e7d072c983cd304 — edit the family, not this file.

variable_name = "total"
expected      = 3

_MISSING = object()
actual = getattr(student_module, variable_name, _MISSING)
if actual is _MISSING:
    failed(
        f"Variable `{variable_name}` is not defined\n"
        f"  expected: {expected!r}\n"            )

if actual != expected:
    failed(
        f"Variable `{variable_name}` has the wrong value\n"
        f"  expected: {expected!r}\n"
        f"  got:      {actual!r}\n"            )

passed(f"{variable_name} == {actual!r}")
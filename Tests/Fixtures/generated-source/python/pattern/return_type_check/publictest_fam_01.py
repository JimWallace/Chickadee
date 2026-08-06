# Test: t
# Generated from pattern family "Family" [fam] spec_hash=8adb8f0c701a46e7 — edit the family, not this file.

x = 1
expected_type_name = "int"

try:
    result = student_module.classify(x)
except Exception as ex:
    import traceback as _tb
    _tb_frames = _tb.extract_tb(ex.__traceback__)
    _tb_src = ""
    if _tb_frames and _tb_frames[-1].line:
        _tb_src = f"\n  source:   {_tb_frames[-1].line.strip()}"
    failed(
        "unexpected exception\n"
        f"  input:    x={x!r}\n"
        f"  expected: a {expected_type_name} return value\n"
        f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\n"            )

if not (isinstance(result, int) and not isinstance(result, bool)):
    failed(
        "wrong return type\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected_type_name}\n"
        f"  got:      {type(result).__name__} (value: {result!r})\n"            )

passed(f"Returned a {type(result).__name__}")
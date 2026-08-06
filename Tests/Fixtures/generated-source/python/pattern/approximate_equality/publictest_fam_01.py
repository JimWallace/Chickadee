# Test: b
# Generated from pattern family "Family" [fam] spec_hash=8fff023f74a1087a — edit the family, not this file.

x = 18.49
expected = 1
tolerance = 1e-06

try:
    result = student_module.classify(x)
except Exception as ex:
    # v0.4.105: see renderBoundaryEquality — append source line for
    # traceback context (especially useful for bare AssertionError).
    import traceback as _tb
    _tb_frames = _tb.extract_tb(ex.__traceback__)
    _tb_src = ""
    if _tb_frames and _tb_frames[-1].line:
        _tb_src = f"\n  source:   {_tb_frames[-1].line.strip()}"
    failed(
        "unexpected exception\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected!r} (±{tolerance})\n"
        f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\n"            )

if not isinstance(result, (int, float)) or isinstance(result, bool):
    failed(
        "wrong return type\n"
        f"  input:    x={x!r}\n"
        f"  expected: a number close to {expected!r}\n"
        f"  got:      {result!r} (type {type(result).__name__})\n"            )

delta = abs(result - expected)
if delta > tolerance:
    failed(
        "value outside tolerance\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected!r} (±{tolerance})\n"
        f"  got:      {result!r}\n"
        f"  delta:    {delta}\n"            )

# v0.4.105: see renderBoundaryEquality — drop the input echo.
passed(f"Returned {result!r} (within ±{tolerance})")
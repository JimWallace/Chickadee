# Test: d
# Generated from pattern family "Family" [fam] spec_hash=361fdde69ad33755 — edit the family, not this file.

x = 18.49

# Instructor's reference implementation, rendered verbatim.
def ck_ref_classify(x):
    return 1

try:
    expected = ck_ref_classify(x)
except Exception as ex:
    errored(
        "the reference implementation raised\n"
        f"  input:    x={x!r}\n"
        f"  error:    {type(ex).__name__}: {ex}\n"            )

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
        f"  expected: {expected!r}\n"
        f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\n"            )

if result != expected:
    failed(
        "wrong value\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected!r}\n"
        f"  got:      {result!r}\n"            )

passed(f"Returned {result!r}")
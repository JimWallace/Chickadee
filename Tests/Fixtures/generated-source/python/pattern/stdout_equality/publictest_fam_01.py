# Test: s
# Generated from pattern family "Family" [fam] spec_hash=fc8371b5e923b61d — edit the family, not this file.

import io as _io
import contextlib as _contextlib

x = 1
expected = "hello"

_buf = _io.StringIO()
try:
    with _contextlib.redirect_stdout(_buf):
        student_module.classify(x)
except Exception as ex:
    # Same traceback-context trick as renderBoundaryEquality —
    # bare AssertionErrors get a `source:` line so the student
    # sees which line raised.
    import traceback as _tb
    _tb_frames = _tb.extract_tb(ex.__traceback__)
    _tb_src = ""
    if _tb_frames and _tb_frames[-1].line:
        _tb_src = f"\n  source:   {_tb_frames[-1].line.strip()}"
    failed(
        "unexpected exception\n"
        f"  input:    x={x!r}\n"
        f"  expected stdout: {expected!r}\n"
        f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\n"            )

# Trim a single trailing newline on both sides so `print("hi")`
# (which emits "hi\n") matches an instructor-typed Expected of "hi".
# Internal newlines and leading whitespace are preserved.
actual = _buf.getvalue()
if actual.endswith("\n"):
    actual = actual[:-1]
expected_norm = expected
if isinstance(expected_norm, str) and expected_norm.endswith("\n"):
    expected_norm = expected_norm[:-1]

if actual != expected_norm:
    failed(
        "wrong stdout\n"
        f"  input:    x={x!r}\n"
        f"  expected: {expected_norm!r}\n"
        f"  got:      {actual!r}\n"            )

passed(f"Printed {actual!r}")
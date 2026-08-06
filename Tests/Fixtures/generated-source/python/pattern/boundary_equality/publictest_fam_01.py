# Test: b
# Generated from pattern family "Family" [fam] spec_hash=567149c178ff72bc — edit the family, not this file.

x = 18.49
expected = 1

try:
    result = student_module.classify(x)
except Exception as ex:
    # v0.4.105: bare AssertionError (`assert x == y` with no message)
    # used to render as just `error: AssertionError:` with no context.
    # Walk the traceback's last frame to pull the source line that
    # actually raised — this gives `error: AssertionError -- assert
    # name == record["name"]["given"]`, which tells the student
    # exactly which assertion failed.  Falls back silently when the
    # traceback can't be extracted.
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

# v0.4.105: pass message no longer echoes the full input dict / list
# (which can be hundreds of characters for HL7-shaped records).  The
# row's case label already names the test ("Example", "Test 1", …);
# the failure path still emits the full input alongside expected/got,
# so we only lose redundant context.
passed(f"Returned {result!r}")
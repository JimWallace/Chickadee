# Test: p
# Generated from pattern family "Family" [fam] spec_hash=373c736715269bba — edit the family, not this file.

import time as _time

x = 1
threshold_ms = 0.5

_start = _time.perf_counter()
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
        f"  threshold: {threshold_ms} ms\n"
        f"  error:     {type(ex).__name__}: {ex}" + _tb_src + "\n"            )
_elapsed_ms = (_time.perf_counter() - _start) * 1000.0

if _elapsed_ms > threshold_ms:
    failed(
        "ran too slowly\n"
        f"  input:    x={x!r}\n"
        f"  threshold: {threshold_ms} ms\n"
        f"  elapsed:   {_elapsed_ms:.2f} ms\n"            )

passed(f"Completed in {_elapsed_ms:.2f} ms (threshold {threshold_ms} ms)")
# Test: u
# Generated from pattern family "Family" [fam] spec_hash=742f48b545094cfb — edit the family, not this file.

x = 1
expected = [1, 2]

# Order-insensitive comparison: canonicalise each element (JSON with
# sorted keys, str() fallback for non-JSON values) and compare the
# sorted multisets, so a correct-but-reordered result still passes.
import json as _ck_json
def _ck_canon(seq):
    return sorted(_ck_json.dumps(_e, sort_keys=True, default=str) for _e in seq)

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
        f"  expected (any order): {expected!r}\n"
        f"  error:    {type(ex).__name__}: {ex}" + _tb_src + "\n"            )

if not isinstance(result, list):
    failed(
        "wrong return type\n"
        f"  input:    x={x!r}\n"
        f"  expected: a list (any order) like {expected!r}\n"
        f"  got:      {result!r} (type {type(result).__name__})\n"            )

try:
    _ck_match = _ck_canon(result) == _ck_canon(expected)
except Exception as ex:
    failed(
        "could not compare result\n"
        f"  input:    x={x!r}\n"
        f"  expected (any order): {expected!r}\n"
        f"  got:      {result!r}\n"
        f"  error:    {type(ex).__name__}: {ex}\n"            )

if not _ck_match:
    failed(
        "wrong elements (order doesn't matter)\n"
        f"  input:    x={x!r}\n"
        f"  expected (any order): {expected!r}\n"
        f"  got:      {result!r}\n"            )

passed(f"Returned the expected {len(result)} element(s) (any order)")
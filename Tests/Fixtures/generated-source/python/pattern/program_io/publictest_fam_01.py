# Test: io
# Generated from pattern family "Family" [fam] spec_hash=eb00ef813bc014b0 — edit the family, not this file.

import builtins as _builtins
import contextlib as _contextlib
import io as _io
import re as _re
import runpy as _runpy
import sys as _sys
import test_runtime as _tr

stdin_text = "3\n4\n"
expected = "7"

_files = _tr._ordered_student_files()
if not _files:
    errored("No Python submission file was found to run.")


def _normalize(text):
    lines = [line.rstrip() for line in str(text).replace("\r\n", "\n").split("\n")]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


_stdin = _io.StringIO(stdin_text)
_out = _io.StringIO()
_saved_stdin, _saved_input = _sys.stdin, _builtins.input


def _fed_input(prompt=""):
    _sys.stdout.write(str(prompt))
    line = _stdin.readline()
    if not line:
        raise EOFError("EOF when reading a line")
    return line.rstrip("\n")


_error = None
try:
    _sys.stdin = _stdin
    _builtins.input = _fed_input
    with _contextlib.redirect_stdout(_out):
        try:
            _runpy.run_path(str(_files[0]), run_name="__main__")
        except SystemExit:
            pass
        except BaseException as ex:
            _error = f"{type(ex).__name__}: {ex}"
finally:
    _sys.stdin = _saved_stdin
    _builtins.input = _saved_input

actual = _normalize(_out.getvalue())
if _error is not None:
    failed(
        "unexpected exception\n"
        f"  input:    {stdin_text!r}\n"
        f"  got:      {actual!r}\n"
        f"  error:    {_error}\n"
    )

_ok = actual == _normalize(expected)
if not _ok:
    failed(
        "wrong output\n"
        f"  input:    {stdin_text!r}\n"
        f"  expected: {expected!r}\n"
        f"  got:      {actual!r}\n"
    )

passed("Printed the expected output")
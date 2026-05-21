# sitecustomize.py — Chickadee test-runtime bootstrap.
#
# Auto-imported by Python on startup; makes the test_runtime helpers
# (passed/failed/errored/require_function) and the loaded student module(s)
# available as builtins so test scripts can use them without an import.
#
# CANONICAL SOURCE.  This file is mirrored verbatim (code, not comments) into:
#   * Sources/Worker/TestRuntimeSources.swift  (the `sitecustomizePy` literal)
#   * Public/browser-runner.js                 (the `SITECUSTOMIZE_PY` literal)
# RuntimeSourceDriftTests (Swift) and the browser-runner JS drift test fail CI
# if any copy drifts.  Edit this file, then re-sync the two embeds.

import builtins
import test_runtime as _tr

builtins.passed = _tr.passed
builtins.failed = _tr.failed
builtins.errored = _tr.errored
builtins.require_function = _tr.require_function

_student_modules = _tr.load_student_modules()
builtins.student_modules = _student_modules
_student_module = _tr.load_student_module()
builtins.student_module = _student_module
for _module_name in _tr.student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith("_"):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)

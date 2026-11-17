### Fixed

- **Browser-graded Python treats a submission's `sys.exit()` as the native
  runner does.** A `SystemExit` raised in the submission's own code is now an
  error in the browser too; before, a submission's `sys.exit(0)` read as a
  pass there. Both graders call one check, `_check_submission_exit` in
  `test_runtime.py`, and the native error now names the test rather than
  `<string>`. The browser cell also sets `sys.argv[0]` and `__file__` to the
  script, as `python3 script.py` does.

### Changed

- **The kernel environment guard compares whole specs, both ways.**
  `check-env-vendored-sync.sh` now fails on a changed constraint and on a
  package dropped from an environment file but still vendored, not only on a
  missing name. It and `build-jupyterlite.sh` find the environments by glob.
  `check-xeus-vendored.sh` fails when a Python module index was derived on a
  different Python minor version than the kernel's.

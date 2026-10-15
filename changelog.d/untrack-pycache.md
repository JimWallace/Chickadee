### Fixed

- **Python bytecode is no longer tracked.** `scripts/__pycache__/patch-xeus-python-http.cpython-313.pyc` was committed by accident, and each run of `check-xeus-vendored.sh` rewrote it, so the guard left the working tree dirty. `.gitignore` now ignores `__pycache__/` and `*.pyc` in the whole repository.

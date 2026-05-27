### Fixed

- **In-browser notebook editor kernel failed to start (`kernel-unhealthy` /
  `watchdog_timeout`).** `scripts/add-pyodide-extras.py` keyed the injected
  `nb_mypy` wheel in `pyodide-lock.json` under its raw project name, but Pyodide
  resolves packages by their PEP 503 canonical name (`nb-mypy`). Since the
  editor kernel loads `nb_mypy` eagerly at boot, `loadPackage` raised "No known
  package with name 'nb_mypy'" and the whole kernel died. The injector now
  normalizes the lock key, the vendored lock is corrected, and
  `scripts/check-pyodide-parity.sh` now fails CI if any package the kernel loads
  at boot can't be resolved in the lock under its canonical name.

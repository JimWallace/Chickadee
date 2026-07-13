### Changed

- **JupyterLite bumped to 0.8.1 (was 0.8.0); Pyodide re-vendored at 314.0.1
  (was 314.0.0).** The point releases carry two fixes that map onto observed
  editor failure classes: JupyterLite 0.8.1 makes kernel shutdown actually
  complete (0.8.0's shutdown could hang, restart detection was timer-based, and
  a failed restart left the session dirty — so a student's Kernel → Restart on a
  wedged cell could silently no-op, and the not-shut-down kernel left the old
  ~hundreds-of-MB Pyodide worker alive alongside the new one, feeding the
  Safari/low-RAM `wasm_crash` class), and Pyodide 314.0.1 fixes
  `PyodideFuture.then()/finally_()` hanging on cancelled futures plus per-cell
  proxy/buffer memory leaks, alongside string/proxy conversion speedups. All
  359 package files are byte-identical to 314.0.0 (sha-verified against the
  official lock); only the core runtime changed. The re-vendor also dropped
  ~45 MB of files in `Public/pyodide` that its own `pyodide-lock.json` never
  referenced — stale prior-version wheels left behind by an earlier vendor
  pass (`scipy-1.17.0` beside the referenced `1.17.1`, `pytest-8.3.5` beside
  `9.0.2`, old `coverage`/`pluggy`/`iniconfig`/`pycparser`/`tblib`) plus
  Pyodide's self-test fixtures (`test_*` wheels/zips) — none of which the
  kernel or micropip could ever load. The chdir `exec_hang` wheel
  patch, nb_mypy-disabled activation block, and the vendored extras
  (`comm`/`astor`/`mypy_extensions`/`nb_mypy`) all re-applied and re-verified
  (`check-pyodide-parity.sh`, `check-kernel-deps-vendored.py`,
  `verify-jupyterlite.sh`).

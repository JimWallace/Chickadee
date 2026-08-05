### Fixed

- **The editor and browser-grading Python environment now actually contains
  scipy, sympy, scikit-learn and statsmodels.** `environment-python.yml` had
  listed them since the xeus-python migration and a release announced them as
  available, but adding a name to that file changes nothing until the kernel is
  rebuilt — and the vendored bytes had never been rebuilt, so `import scipy`
  would have failed with an unrecoverable `ImportError` for any student whose
  test used it. The kernels are re-vendored, and a browser probe now asserts
  every declared package genuinely imports in a real kernel rather than merely
  being present in the tarballs.

- **The re-vendored kernel would not have booted at all without a second
  library patch.** `scikit-learn` pulls in `requests` → `urllib3`, and
  `urllib3.contrib.emscripten.fetch` constructs a Pyodide-only streaming fetcher
  at module import under exactly the conditions a grading worker meets. That
  raised out of `xkernel.start()`, so the failure was total rather than
  degraded. `scripts/patch-xeus-python-http.py`, which already neutralised the
  identical hazard in `pyodide-http`, now covers urllib3 too, and
  `check-xeus-vendored.sh` asserts it — an un-patched re-vendor is a CI failure
  rather than a dead editor. Nothing short of booting a real kernel could have
  caught this: the environment solves cleanly and every other guard passes.

### Added

- **Re-vendoring the xeus kernels is a CI workflow, not a manual step.**
  `.github/workflows/revendor-kernels.yml` rebuilds the JupyterLite bundle and
  both kernel environments and commits the result — on demand, or when a pull
  request changes an environment file. "CI cannot do this, it needs micromamba
  and network to repo.prefix.dev" had been the standing assumption and it was
  simply wrong: a hosted runner has unrestricted network and micromamba is a
  single ~7 MB download. Believing otherwise is what allowed the environment
  file and the shipped kernel to drift apart for a whole release.

- **`scripts/check-env-vendored-sync.sh` fails when they drift again.** It is the
  only guard that compares *declared intent* to *shipped bytes*; every other one
  compares the vendored tree to itself, which is why none of them could see four
  missing packages. It costs two file reads, runs on every JupyterLite-relevant
  PR, and points at the workflow that fixes it.

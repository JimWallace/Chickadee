### Changed

- **CI now fails if the in-browser editor kernel would need an external fetch at
  boot.** `scripts/check-kernel-deps-vendored.py` (run in the JupyterLite job)
  scans the kernel wheels' startup imports and asserts every one is provided by
  the locally-vended Pyodide. A missing package would fall through to
  `piplite.install(...)` → CDN/PyPI, which FIPPA blocks — the class of regression
  behind the `comm` and mypy-deps editor outages. The kernel wheels declare no
  dependencies, so this scans imports rather than metadata; it catches a gap in
  CI instead of on a student's screen.

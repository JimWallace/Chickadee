### Changed

- **The editor's Python kernel is now xeus-python; both editor kernels come from
  one env.** `Tools/jupyterlite/environment.yml` builds `xpython`
  (xeus-python 0.19.0, Python 3.13.1) and `xr` (xeus-r 0.11.2, R 4.5.3) from a
  single emscripten-forge environment, so authoring runs one kernel technology
  for both languages. Notebooks normalize to `xpython` / `xr`; new starter
  scaffolds are written with the `xpython` kernelspec. Verified in headless
  Chromium against the vendored bytes: both kernels boot and execute
  cross-origin isolated, pandas/numpy/matplotlib import, and the boot makes zero
  external network requests.
- **Kernel builds moved to the `emscripten-forge-4x` channel.** The
  `emscripten-forge-dev` alias the R kernel was pinned to serves the frozen 3x
  (emscripten 3.x ABI) channel — its last build of any package was 2026-04-09 —
  so the vendored R kernel was tracking a channel that no longer receives fixes.
  This also unblocked Phase 3 of the xeus spike: xeus-python has been built
  against xeus 6 with a real `run_exports` pin since 0.18.1 (2026-03-09), which
  is the supported pairing the spike said to wait for.
- **`scripts/check-xeus-vendored.sh` now guards both kernels.** It asserts
  `xpython` and `xr` are registered, share one env, declare the right language,
  and each have both a loader and its `.wasm` beside it — so a partial
  re-vendor fails in CI rather than in front of a student.

### Known issues

- **Python notebooks no longer work on WebKit (Safari / iPad).** `COEPMiddleware`
  deliberately serves WebKit non-isolated, and xeus kernels hard-require
  SharedArrayBuffer with no fallback, so Python on Safari goes from working
  (Pyodide + service-worker fallback) to no kernel at all; R was already
  unavailable there for the same reason. Resolving it means re-testing whether
  Pyodide/coincident still deadlocks isolated Safari and, if not, dropping the
  WebKit exemption. Needs a real device.
- **Editor and browser grader are no longer the same Python.** Authoring runs
  xeus-python 3.13; browser grading and `/validate` still run Pyodide 3.14. The
  native worker remains the authoritative grader, so marks are unaffected.

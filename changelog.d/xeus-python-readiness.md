### Changed

- **The editor's Python kernel is now xeus-python.**
  `Tools/jupyterlite/environment-python.yml` and `environment-r.yml` build
  `xpython` (xeus-python 0.19.0, Python 3.13.1) and `xr` (xeus-r 0.11.2,
  R 4.5.3), so authoring runs one kernel technology for both languages.
  Notebooks normalize to `xpython` / `xr`; new starter scaffolds are written
  with the `xpython` kernelspec. Verified in headless Chromium against the
  vendored bytes: both kernels boot and execute cross-origin isolated,
  pandas/numpy/matplotlib import, and the boot makes zero external network
  requests.
- **Each kernel gets its own emscripten-forge env.** A xeus kernel fetches its
  whole env at boot, so building Python and R into one shared env made every
  Python boot pull all of `r-base` and every R boot pull numpy/pandas/
  matplotlib — slow enough to time out the editor probes with "kernel never
  reported idle". `check-xeus-vendored.sh` now asserts the two envs stay
  distinct, and that neither has acquired the other's packages, so a re-vendor
  cannot silently recombine them.
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

### Fixed

- **The editor kernel no longer hangs on cross-origin-isolated engines.**
  `pyodide-http` (an unavoidable dependency of `xeus-python-shell-lite`) selects
  a Pyodide-specific streaming implementation whenever `crossOriginIsolated` is
  true. It is not pyjs-compatible, so on Chromium the kernel never left
  `kernel_starting` and the editor sat on "Kernel Connecting" indefinitely;
  WebKit, which Chickadee serves non-isolated on purpose, took the library's
  XMLHttpRequest fallback and worked fine. `scripts/patch-xeus-python-http.py`
  forces that fallback on every engine — upstream's own documented degradation
  for non-isolated contexts — and `check-xeus-vendored.sh` asserts it on the
  committed bytes, since the fault is invisible both in the JupyterLite REPL and
  on WebKit.

### Known issues

- **Editor and browser grader are no longer the same Python.** Authoring runs
  xeus-python 3.13; browser grading and `/validate` still run Pyodide 3.14. The
  native worker remains the authoritative grader, so marks are unaffected.

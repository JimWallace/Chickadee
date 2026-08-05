### Added

- **The editor smoke matrix now probes `input()` against the kernel students
  actually get.** The selftest runs `?kernel=python` — the Pyodide kernel, which
  since v0.5.14 is no longer the editor default (`defaultKernelName` is
  `xpython`). Without this, every stdin and freeze-detector result we had
  described a kernel nobody boots. The new step is blocking on both engines, and
  both must run: they use different synchronous-stdin transports, so a change
  that breaks only one would otherwise ship green. Chromium is cross-origin
  isolated and carries stdin over `SharedArrayBuffer`; WebKit is served
  non-isolated and carries it over the service worker, which
  `JupyterLiteConfigFlagMiddleware` re-enables per request for that engine.
  Measured: `input()` round-trips on both.

### Changed

- **Corrected three stale editor-kernel claims.** `docs/xeus-r-kernel-spike.md`
  asserted that xeus "hard-requires SharedArrayBuffer with no fallback" —
  untrue, and load-bearing: it is why we believed moving Python to xeus would
  break Safari, and why #1270 briefly shipped a changelog entry describing a
  Safari regression that does not exist. The same document still routes builds
  through `emscripten-forge-dev`, frozen since 2026-04-09.
  `docs/notebook-editor-kernel-boot.md` separately described cross-origin
  isolation as "unconditional" when `COEPMiddleware` exempts WebKit, and
  described the service worker as disabled when that is true of Chromium only.
  All three now record what was measured, when, and against which kernel.

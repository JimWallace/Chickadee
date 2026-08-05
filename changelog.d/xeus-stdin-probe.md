### Changed

- **Corrected two stale editor-kernel claims, and added a probe for the one
  question they were hiding.** `docs/xeus-r-kernel-spike.md` asserted that xeus
  "hard-requires SharedArrayBuffer with no fallback" — untrue, and load-bearing:
  it is why we believed moving Python to xeus would break Safari. Upstream ships
  both a non-isolated transport and two stdin paths, and v0.5.14's CI measured
  every WebKit probe passing with the xeus kernels served non-isolated.
  `docs/notebook-editor-kernel-boot.md` separately describes cross-origin
  isolation as "unconditional" when `COEPMiddleware` exempts WebKit, and records
  stdin results measured against the Pyodide kernel that is no longer the
  editor's default. Both are annotated with what was actually measured.
- **`editor-smoke.yml` now probes `input()` against the kernel students get.**
  The existing selftest runs `?kernel=python` (Pyodide); the editor default is
  `xpython`. Whether `input()` works for xeus on a non-isolated engine — where
  we have neither SharedArrayBuffer nor (being disabled) the service worker — is
  unmeasured, and cannot be answered by simulating non-isolation on Chromium,
  since that yields a half-isolated state which fails xeus before the kernel
  executes. The new step is informational on both engines pending an expected
  value; see #1271.

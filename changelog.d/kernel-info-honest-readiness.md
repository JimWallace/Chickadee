### Fixed

- **Notebook editor no longer presents a still-booting kernel as ready
  (WebKit slow-first-execute).** The vended pyodide-kernel answered
  `kernel_info_request` immediately (not gated on `this.ready`) while the kernel
  was still compiling WASM and importing IPython at boot, so the execution
  indicator went "idle" and a cell run in that window silently blocked on
  `await this.ready` for the rest of boot — ~13-17s on ~30% of WebKit sessions,
  the slow-first-execute whose tail was the residual `exec_hang`
  (docs/exec-hang-investigation.md, second issue). `kernelInfoRequest` now also
  `await`s `this.ready`, so the kernel shows "Connecting" until it can actually
  execute rather than idle-that-hangs, and the boot-funnel telemetry stops
  counting still-booting kernels as idle. Applied as a deterministic post-build
  patch (`scripts/patch-pyodide-kernel-info-ready.py`). Does not speed boot;
  makes readiness honest.

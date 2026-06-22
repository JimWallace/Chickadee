### Fixed

- **Notebook editor: restore a kernel-boot fallback and stop hung kernels from
  hiding.** After the SAB-only switch (cross-origin isolation, service worker
  removed) some students hit a Pyodide kernel that never finished loading. Two
  causes: (1) a stale, now-redundant JupyterLite service worker left registered
  by a pre-SAB build kept controlling `/jupyterlite/*` and broke the boot — it is
  now proactively unregistered on load; (2) engines that lack native
  `Atomics.waitAsync` (older Safari / iPadOS) hit the kernel's `data:`-worker
  polyfill, which COEP `require-corp` blocks, hanging the kernel with no
  fallback. notebook.js now detects that exact case (`crossOriginIsolated &&
  !Atomics.waitAsync`), opts the client out of isolation via the
  `ck-editor-compat` cookie (the isolation middlewares drop COEP for that
  client only), and re-registers the JupyterLite service worker so the kernel
  uses the SW sync path — the cross-origin-isolated majority is unchanged.

### Added

- **Kernel-liveness telemetry so a hung kernel is visible.** The editor now
  beacons `kernel_ready` when the Pyodide kernel actually reaches idle/busy (not
  just the shell mounting, which `editor_ready` already counted), and a
  `watchdog_timeout` / `kernel-boot-timeout` diagnostic when it never does —
  tagged with `coi` / `waitasync` / `compat` so the admin browser-diagnostics
  surface shows which kernels are hanging and why, instead of recording a hung
  kernel as a successful load.

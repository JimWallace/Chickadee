### Added

- **In-iframe kernel-boot diagnostics — closing the cross-process blind spot.**
  The parent notebook page can't read the Pyodide kernel's state across the
  cross-process editor iframe (the Safari/iPad case where a hung kernel still
  left the parent reporting a green `editor_ready`), so a spinning-forever kernel
  was invisible to telemetry. A new passive collector
  (`Public/jl-kernel-diagnostics.js`) is injected into the JupyterLite editor
  documents and runs *inside* the iframe — the one context where the boot is
  visible. It postMessages two breadcrumb kinds to the parent, which forwards
  them through the existing client-diagnostics pipeline (session + CSRF):
  `kernel_phase` (`boot_start → app_ready → kernel_starting → kernel_idle`, the
  boot funnel whose drop-off localizes *where* a boot stalls) and `kernel_error`
  (CSP worker block, blocked/404 asset, dead/unknown kernel, or boot-stall — the
  *why*). Capture is scoped to the boot window, so no student-code execution is
  ever recorded. `get_browser_diagnostics` gains a `kernelBootFunnel` over the
  `kernel_phase` events (a `kernel_idle` count far below `boot_start` is the
  hung-kernel signature). The collector is injected at build time
  (`scripts/patch-jupyterlite-diagnostics.py`, run from `build-jupyterlite.sh`)
  and asserted present by `verify-jupyterlite.sh`; the editor-smoke harness
  asserts it actually runs in a real browser under the live CSP/COEP.

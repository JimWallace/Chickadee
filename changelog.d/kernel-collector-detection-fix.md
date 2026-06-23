### Fixed

- **Kernel-boot collector now actually detects the kernel (and stops polling).**
  The in-iframe collector shipped in the previous diagnostics work read kernel
  state from `window.jupyterapp.serviceManager` — but this JupyterLite build
  (Notebook 7) does not expose `window.jupyterapp` at all (which is also why the
  parent-side watchdog was blind). So the collector never advanced past
  `boot_start`: the `kernelBootFunnel` was stuck, every healthy editor open
  emitted a spurious `kernel_error: boot_stalled` after the 75 s deadline, and —
  the user-visible part — the collector's 1 Hz poll (which walked the notebook
  DOM via `document.body.textContent`) ran for the full 75 s on every open,
  competing with the student's editing/execution. Detection now reads the shell
  DOM the editor actually renders — the execution indicator's `data-status`
  (`.jp-Notebook-ExecutionIndicator[data-status]`), with "Kernel status: …" text
  as a fallback — so it reports the real funnel and terminates within seconds of
  the kernel idling. The authenticated `notebook-page-check.mjs` smoke test
  (chromium + webkit, in CI) now asserts the funnel reaches `kernel_idle` in the
  real notebooks editor, so this can't silently regress.

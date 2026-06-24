### Fixed

- **Editor: self-heal post-idle kernel hangs.** A Pyodide kernel that booted to
  idle and then wedged BUSY forever on a later cell (the `[*]`-forever
  `exec_hang` — invisible to the boot funnel and the watchdog, which both stop at
  kernel-ready) now auto-recovers: the parent bridge escalates iframe-reload →
  page-reload → upload-fallback, each sessionStorage-guarded so it can't loop.
  JupyterLite restores the student's saved notebook from IndexedDB on reboot, so
  no work is lost. The self-heal emits `recover_attempt` (a reload rung fired) and
  `recover_failed` (the ladder was exhausted and the kernel hung again) through
  the existing `kernel_error` pipeline, so **success ≈ attempts − failures** and
  both fall toward zero once the underlying SAB/Atomics deadlock is fixed — the
  headline KPI for that root-cause work. Surfaced in `get_browser_diagnostics`
  `bySource`.

### Added

- **`editorKernelHang` health-alert rule.** Fires when at least
  `ALERT_EDITOR_HANG_THRESHOLD` (default 3) post-idle `exec_hang` reports land
  within `ALERT_EDITOR_HANG_WINDOW_MINUTES` (default 60) — the recurrence
  tripwire for the SharedArrayBuffer/Atomics kernel deadlock, which is otherwise
  invisible server-side until students complain. Surfaced in `get_health_alerts`.
- **CI exec-hang reproducer (`editor-exec-probe` workflow).** A non-gating
  diagnostic (`Tools/editor-smoke-test/editor-exec-check.mjs`) seeds a real
  browser-graded assignment, opens the **real** notebook page, waits for
  `kernel_idle`, then runs an editor cell and measures the hang rate per engine
  (chromium + webkit) — the post-idle editor-cell execute the required smoke
  never exercised. While the root cause is open a reproduced hang is the signal,
  not a merge blocker; once consistently green it becomes a regression guard.
- **Post-idle execute smoke guard.** The editor-smoke harness gains an opt-in
  `SMOKE_POST_IDLE_MS` probe (wired as a 5th `selftest.sh` config) that idles,
  then executes a cell in the REPL — a cheap lifecycle guard alongside the
  real-page reproducer above.

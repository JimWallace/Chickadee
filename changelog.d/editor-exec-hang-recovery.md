### Fixed

- **Editor: self-heal post-idle kernel hangs.** A Pyodide kernel that booted to
  idle and then wedged BUSY forever on a later cell (the `[*]`-forever
  `exec_hang` — invisible to the boot funnel and the watchdog, which both stop at
  kernel-ready) now auto-recovers: the parent bridge escalates iframe-reload →
  page-reload → upload-fallback, each rung sessionStorage-guarded so it can't
  loop. JupyterLite restores the student's saved notebook from IndexedDB on
  reboot, so no work is lost.

### Added

- **`editorKernelHang` health-alert rule.** Fires when at least
  `ALERT_EDITOR_HANG_THRESHOLD` (default 3) post-idle `exec_hang` reports land
  within `ALERT_EDITOR_HANG_WINDOW_MINUTES` (default 60) — the recurrence
  tripwire for the SharedArrayBuffer/Atomics kernel deadlock, which is otherwise
  invisible server-side until students complain. Surfaced in `get_health_alerts`.
- **Post-idle execute smoke guard.** The editor-smoke harness gains an opt-in
  `SMOKE_POST_IDLE_MS` probe (wired as a 5th `selftest.sh` config) that idles,
  then executes a cell — closing the lifecycle gap that hid `exec_hang` (every
  other probe ran at t≈0). It guards that post-idle execution works at all; it
  cannot reproduce the production hang, since a headless tab is never throttled.

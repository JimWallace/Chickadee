### Added

- **`editorKernelHang` health-alert rule.** Fires when at least
  `ALERT_EDITOR_HANG_THRESHOLD` (default 3) post-idle `exec_hang` reports land
  within `ALERT_EDITOR_HANG_WINDOW_MINUTES` (default 60) — the recurrence
  tripwire for the SharedArrayBuffer/Atomics kernel deadlock, which is otherwise
  invisible server-side until students complain. Complements the editor's
  client-side self-heal (v0.4.523): the self-heal recovers the *student*, this
  pages the *operator* when the rate spikes. Surfaced in `get_health_alerts`.
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

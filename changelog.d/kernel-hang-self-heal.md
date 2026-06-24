### Added

- **Self-heal for post-idle kernel execution hangs, with KPI telemetry.** When
  the in-iframe collector reports an `exec_hang` (the kernel booted to idle then
  wedged on a cell — the `[*]`-forever deadlock), the editor now **auto-reloads
  the kernel iframe once** via the existing work-preserving recovery path
  (JupyterLite restores the student's saved copy from IndexedDB on boot), instead
  of leaving the student stuck. Guarded to once per page so a persistently
  deadlocking kernel can't reload-loop; a second hang surfaces the `/reset-editor`
  fallback. The recovery emits two breadcrumbs — `recover_attempt` (the self-heal
  fired) and `recover_failed` (the rebooted kernel hung again) — so success ≈
  attempts − failures, and both fall toward zero once the underlying kernel
  deadlock is actually fixed (the headline metric for that root-cause work).
  Reuses the `kernel_error` pipeline (no server change); surfaced in
  `get_browser_diagnostics` `bySource`.

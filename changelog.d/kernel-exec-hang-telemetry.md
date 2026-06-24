### Added

- **Post-idle kernel execution-hang telemetry (`exec_hang`).** The in-iframe
  kernel diagnostics collector previously stopped the instant the kernel reached
  `kernel_idle` — so a kernel that booted fine and *then* wedged on cell execution
  (the `[*]`-forever hang) was invisible to both the boot funnel and the
  watchdog's recovery. The collector now keeps one narrow, PII-safe watcher alive
  past idle: it polls only the busy/idle status indicator (never the notebook
  content) and emits a single `kernel_error` with source `exec_hang` (message
  `busy_ms=…`, a duration only) when a cell sits `busy` past a threshold
  (`EXEC_HANG_MS`, 45s). It rides the existing parent-bridge / `kernel_error`
  path, so no server change is needed; `get_browser_diagnostics` surfaces it in
  `bySource`, where the count is the number of distinct students who hit a
  post-idle hang. Boot-window error capture still stops at idle, preserving the
  existing PII contract.

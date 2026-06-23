### Fixed

- **In-iframe kernel diagnostics no longer report a transient "Kernel
  Unknown".** A healthy JupyterLite boot routinely flashes a momentary
  `unknown`/`dead` kernel status for a beat before it reaches idle, and the
  collector was emitting a `kernel_error` on the first such poll — a false
  positive on most *successful* boots (observed where 11/11 real boots reached
  `kernel_idle`). It now starts a clock on the first unhealthy poll and reports
  only once the state has held continuously for ~10s, resetting the instant the
  status is anything else.

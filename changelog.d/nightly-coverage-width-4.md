### Changed

- **Nightly coverage run parallelism restored to width 4 (from 2).** The
  tighter cap dated from when the all-targets nightly process was losing
  cooperative-pool threads to WorkerTests' blocking subprocess waits on top
  of DB-pool pressure; with the #1233 wedge class fixed and the WedgeWatchdog
  converting any residual stall into a fast evidenced abort, the nightly runs
  at the same width as the per-PR jobs (measured 2× on the WorkerTests slice
  alone). The nightly's retry-once + `::warning` telemetry is the guardrail
  for re-tightening if pool-pressure flakes recur.

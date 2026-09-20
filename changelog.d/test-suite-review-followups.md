### Fixed

- **The hung-make timeout test now runs in CI.** `WorkerDaemonTests` returned
  early when `/usr/bin/make` was absent, and the swift-ci image never carried
  it, so the runner's make-step timeout had no CI execution. The image now
  installs `make`, the worker-tests fallback probes for it, and the guard is a
  visible `.requiresMake` trait.

- **The R evaluator round-trip tests no longer time out under CI load.** They
  used the evaluator's production 5-second subprocess limit while the R,
  Octave, Racket and Lua execution suites ran beside them, and `Rscript`
  start-up alone crossed it on two of four runs. They now pass a 60-second
  budget, since they assert what the driver computes, not how fast R starts.
  The shared `cachedToolIsAvailable` probe is also single-flight, so a target
  with forty `.requiresRscript` tests spawns one probe at plan time, not forty.

### Changed

- **The browser probe workflows use a shallow checkout.** The seven callers of
  `browser-probe-setup` fetched full history for a git mtime restore that the
  scaffold no longer runs.

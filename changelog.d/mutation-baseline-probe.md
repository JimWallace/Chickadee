### Added

- **A dispatch-only probe for the Worker-widening precondition**
  (`mutation-baseline-probe.yml`). Widening the mutation sweep to
  `Sources/Worker` is gated on the full suite — including the 48
  timing-sensitive WorkerTests the sweep currently skips — surviving the
  sweep's own one-process configuration on a hosted runner, since a baseline
  flake costs a whole shard and mutating Worker while its tests are skipped
  would report survivors in exactly the code they cover. The probe runs the
  exact prospective baseline command N times (default 20) in the swift-ci
  container, reports every iteration's result and duration (the durations
  double as the per-mutant cost a Worker shard would pay), keeps running
  after a failure so one flake cannot hide a second, and fails loudly naming
  the flaking tests.

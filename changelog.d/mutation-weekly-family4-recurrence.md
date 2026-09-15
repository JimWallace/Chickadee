### Fixed

- **Weekly mutation sweep: diagnosed the red shard as the known URLSession
  cancellation deadlock, not a broken test.** Shard 0 of run 34959089994 aborted
  in its unmutated baseline, so it measured nothing while the other eleven
  shards passed. The cause is Family 4 in `docs/ci-flakiness.md` — a
  swift-corelibs-foundation lock inversion — reaching it through
  `TestSetupCache.detachWaiter`. That entry now records the recurrence, the
  measured reason a completion-handler rewrite removes the wedge, and the
  measured reason it was reverted rather than shipped: it replaces the deadlock
  with a `fatalError` in Foundation's task registry, which crashed the logic-tier
  suite in 7 of 12 runs. The maintainer's decision is recorded
  with it: accept the rate and re-run the shard, rather than weaken a
  deliberately pinned cancellation property to work around a dependency bug.

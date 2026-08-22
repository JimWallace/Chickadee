### Fixed

- **The wedge-watchdog arming guard no longer races parallel tests.**
  `WedgeWatchdogArmingTests.withAppArmsTheWatchdog` asserted a before/inside
  delta of the process-global tracked-scope counter, which any concurrent
  test's scope could zero out by draining between the two reads — it was the
  sole failure in a 3,045-test `api-tests-postgres` run on a loaded lane
  (2026-08-22). `WedgeWatchdog.track` now also sets a task-local,
  `isInsideTrackedScope`, and the guard asserts that from inside `withApp`:
  another suite's scope can neither satisfy it nor disturb it, so the
  assertion is race-free and strictly stronger. Verified in both directions —
  it fails when the `track` wrapper is stripped from `withApp`.
  `docs/ci-flakiness.md` records the sighting, and marks Family 5's
  ceiling-equalization attack note done (the workflow has carried matching
  25-minute ceilings on both api-tests lanes for some time).

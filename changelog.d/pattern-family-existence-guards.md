### Added

- **Automatic existence guards for pattern families.** Every function-calling
  pattern family (`boundary_equality`, `approximate_equality`,
  `return_type_check`, `exception_expected`, `performance_threshold`,
  `stdout_equality`, `unordered_equality`) now auto-generates one 0-point
  `… is defined` guard test; its cases `dependsOn` the guard, so a missing or
  non-callable target produces a single clear "`fn` is not defined" failure and
  the cases auto-skip through the runner's dependency gate — instead of N opaque
  `AttributeError` tracebacks. `variable_equality` is unchanged (it already
  self-guards each case). The guard is internal: it collapses into the family
  row in the suite editor and is reserved against the case key `exists`. No
  runner changes — the guard is an ordinary generated test and the gating reuses
  the existing `dependsOn` machinery.

### Fixed

- **0-point test entries now round-trip.** `makeWorkerManifestJSON` only
  serialized `points` when greater than 1, so a 0-point entry decoded back to
  the default of 1 and silently started counting toward the score. Any non-1
  value (including 0) is now written explicitly.

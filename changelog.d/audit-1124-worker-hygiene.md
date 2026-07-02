### Changed

- **Worker target hygiene (#1124).** The `chickadee-runner` target no longer
  links Vapor (it never imported it — the dependency predated `RunnerCore`);
  per-student `_ck_inputs.py` and personalized-file materialization moved
  into `prepareJobWorkspace` so every workspace-mutation step lives in one
  place; and the `TestProperties` dual-encode back-compat comment now names
  its exit criterion (remove in the v0.7.0 cleanup). New
  `RunnerSanitizedProjectionTests` pin what `runnerSanitized()` strips.

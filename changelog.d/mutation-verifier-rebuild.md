### Fixed

- **The mutation survivor verifier now forces a rebuild after applying a
  mutation.** It rewrites the same source path repeatedly, and same-tick writes
  could leave SwiftPM's incremental build skipping the recompile, so the suite
  ran the previous binary and the mutant was reported as surviving code it had
  never been compiled into.

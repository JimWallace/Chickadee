### Fixed

- **Nightly clean-build coverage canary restored.** `test-coverage.yml` runs
  every target in one process but never installed `python3`, so the
  python3-dependent APITests (generated pattern-family syntax checks,
  seed-expression validation grading) trapped — a broken-pipe write to a
  never-spawned interpreter, and a test `Application` leaked past a python3-skip
  guard tripping Vapor's `ServeCommand did not shutdown before deinit`
  assertion — each SIGILLing the whole run. The container now installs `python3`
  (matching `swift-tests.yml`); the skip guard in
  `WorkerRoutesTests.materializeValidation_resolvesExpressionForSeed` moved
  inside `withApp` so a skip can't leak the app; and `pfAssertValidPythonSyntax`
  skips cleanly and uses a throwing write so a missing/failed interpreter
  degrades to a skip instead of a process-killing trap.

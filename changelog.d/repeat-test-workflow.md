### Added

- **A workflow that repeats one test until it fails.** `repeat-test.yml`
  takes a `swift test --filter` expression, a repetition count, a stop
  condition and a database backend, and runs the selection on the CI image
  with Swift 6.4's `--maximum-repetitions` and `--repeat-until`. It uploads
  the log and the xUnit report either way and writes a summary table. It
  reproduces a flake that used to be diagnosed from one log; it does not
  reproduce a full lane's load. See "Structural problems" in
  `docs/ci-flakiness.md`.

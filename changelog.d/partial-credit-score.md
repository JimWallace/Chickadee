### Added

- **Per-test partial credit (fractional `score`).** A test script's stdout JSON
  footer `score` (0…1) is now honoured: a test's earned grade is `points × score`
  instead of all-or-nothing. With no footer `score` a test still scores 1 on a
  pass and 0 otherwise, so existing suites grade exactly as before. The logic
  lives in the shared RunnerCore `interpretScriptOutput`, so the native worker
  and the in-browser wasm runner apply identical partial credit, pinned against
  both by `Tests/Fixtures/output-contract.json`. Browser-graded submissions now
  also grade with the instructor's weighted `points` (previously unweighted),
  recomputed server-side; the in-browser artifact emits `score` on the next
  RunnerCore re-vendor.

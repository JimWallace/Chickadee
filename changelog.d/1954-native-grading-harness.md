### Changed

- **The five native-grading suites share one harness (#1954).**
  `Tests/WorkerTests/Support/NativeGradingHarness.swift` builds the grading
  workspace and runs the suites. It replaces five copies of `makeWorkspace`,
  `runSuites` and `item`. Each copy differed only in the language, the
  submission's file name and the time limit, so those are now the harness's
  three fields. Every language now writes its runtime through
  `runtimeHelperFiles(for:)`, as Java and Racket already did.

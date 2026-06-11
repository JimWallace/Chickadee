### Changed

- **Error vocabulary unified.** `WebAssignmentError` is now a typealias of
  `AppError` (its two extra cases folded in), and the bare-`Abort` clusters in
  the test-setup and assignment-edit routes were swept to typed errors. Status
  codes and user-facing messages are unchanged.
- **Oversized files split along their natural seams.** The worker daemon's CLI
  command, structured logging, and staging helpers moved out of
  `RunnerDaemon.swift` (894 → 474 lines); the pattern-family renderer split
  into one file per pattern kind plus a shared-template file (957 → 211 lines
  in the dispatcher) with generated script bytes verified identical by the
  existing renderer tests.
- The `PublishedAssignmentRoutes` handler cluster now resolves assignments and
  setups through the shared `loadAssignmentAndSetup` helper instead of
  repeating the inline lookup-and-404 chain.

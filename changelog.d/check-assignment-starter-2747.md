### Added

- **Two starter-run checks in `check_assignment` (#2747).** `starter.didNotRun`
  reports a starter notebook that, as students receive it, does not build or
  errors on every test, with the same reason the workbench shows.
  `starter.errorsInsteadOfFails` lists graded tests that report an error, not a
  failure, on the unmodified starter while the solution passes them, so a
  student who runs the tests early sees a traceback.

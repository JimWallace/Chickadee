### Changed

- **BrightSpace grade-sync logic is now unit-testable.** A narrow
  `BrightSpaceGrading` protocol seam covers the two network-touching client
  operations (`lookupUserID`, `pushGrade`); the sweep depends on the protocol
  so tests substitute an in-memory fake. Seven new tests cover best-grade
  selection, the debounce window, user-ID caching, missing-account and
  push-failure paths, and the validation-run exclusion. Production behaviour
  unchanged. (#629)

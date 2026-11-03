### Changed

- **One scope for a test's app.** `withTestApp { app in ... }` builds the
  standard test app and tears it down; 571 test bodies that paired
  `makeTestApp` with `withApp` now call it, and `withWebRoutesApp` /
  `withAssignmentRoutesApp` are thin aliases of it (#2717, step 4).

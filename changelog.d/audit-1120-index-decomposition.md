### Changed

- **`WebRoutes.index` decomposed (#1120).** The 445-line student dashboard
  handler's two heavy phases — the per-student grade-data load and the
  per-setup row build — moved to `WebRoutes+IndexRows.swift` as
  `loadStudentDashboardGradeData` and `buildTestSetupRow` (with typed
  `DashboardGradeData` / `IndexRowContext` carriers), leaving the handler as
  state dispatch plus the load/sort/group pipeline. The SwiftLint
  function-length suppression on `index` is gone. No behavior change.

### Changed

- **Route-layer helper adoption completed.** Every web handler that resolved
  an assignment by public ID now goes through the shared `loadAssignment` /
  `loadAssignmentAndSetup` helpers (15 remaining inline lookup chains
  rewired); the per-student instructor pages share one
  `resolveStudentAssignmentAction` preamble and redirect helper instead of
  seven hand-rolled copies.
- **Remaining oversized route files split.** `WebRoutes+Submission.swift`
  (989 → 479 lines, result-presentation pipeline extracted to
  `SubmissionResultPresenter.swift`), `CourseBundleRoutes.swift` (801 → 346,
  import handler extracted), and
  `InstructorDashboardRoutes+Submissions.swift` (850 → 218, grades CSV and
  per-student actions extracted). The shared preferred-result fold moved to
  `Helpers/PreferredResultsBySubmissionID.swift`. Mechanical moves — no
  behavior changes.

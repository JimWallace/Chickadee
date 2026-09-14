### Added

- **Advisory passing threshold.** An assignment can set a best-grade percentage
  (Student Options on the edit page, or `passingThresholdPercent` on the
  `update_assignment` MCP tool) at or above which the instructor submissions
  page labels a student as passing and counts them in a Passing card. It is a
  label only and never changes a grade.
- **Download all submissions.** The instructor submissions page offers one
  zip of every student's latest submission for the assignment, one directory
  per student plus an `index.csv`, for offline marking or a
  similarity-detection run.
- **Diff against starter.** Course staff can open a unified diff of any
  student submission against the assignment's starter, from the submission
  history page or the results view: notebooks cell by cell with instructor
  test cells left out of both sides, single files against the starter file of
  the same name.

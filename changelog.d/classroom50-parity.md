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

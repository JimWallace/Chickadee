### Added

- **Notebook reset on the course-student submissions page.** The existing
  "reset working-copy notebook to starter" action is now surfaced on the
  per-student course submissions page alongside the per-row retest and
  extension controls, via a course-scoped
  `POST /:courseCode/students/:urlToken/assignments/:assignmentID/reset-notebook`
  handler that redirects back to the same page.

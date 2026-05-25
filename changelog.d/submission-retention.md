### Added

- **Submission retention policy (FIPPA / TL55).** Student submissions are now
  governed by a one-year-after-end-of-term retention policy. Archiving a course
  stamps a new `archived_at` timestamp (the "end of term" signal), and a new
  admin **Retention** tab (`/admin/retention`) reports every archived course
  with its archival date, submission count, and the date its submissions become
  purgeable (`SUBMISSION_RETENTION_DAYS`, default 365). The policy is
  report-first: an admin manually triggers a purge from the report, and the
  server only honours it once the retention window has elapsed. Purging removes
  submission files, their results, and diagnostics for that course while leaving
  the course, assignments, test suites, and user accounts intact; grades
  continue to flow to LEARN for TL60 retention. Each archive/unarchive and purge
  is written to the audit log.

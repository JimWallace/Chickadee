### Changed

- **The instructor submissions roster reads one statement less.** The
  per-student summary query already ranks each student's latest submission;
  it now returns that submission's time as well, so the page no longer
  re-reads every latest submission by id. On the course-scale benchmark:
  20 → 19 statements and 4,810 → 4,510 rows per request.

### Changed

- **Assignment display-order rule and section-grouping fold deduplicated
  (#1118).** The dashboard sort comparator existed ×3 (student dashboard,
  per-student submissions page, grades CSV) and the section-grouping loop ×3
  — both now live once in `AssignmentListDisplayHelpers.swift`, alongside a
  shared per-assignment submission-history row builder used by both
  drilldown pages. The runner poll and heartbeat handlers share one
  `recordRunnerCheckIn` path, the preferred-results loader delegates to the
  all-results loader (one chunked-IN implementation), and `parseDueDate`
  accepts the seconds-bearing `datetime-local` variant. No behavior change.

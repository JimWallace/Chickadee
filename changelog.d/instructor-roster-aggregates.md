### Changed

- **The instructor assignment-submissions roster no longer loads every
  attempt to render.** The per-student latest pick, attempt count, and best
  grade are computed by the database (the same window-function and MAX
  aggregates the student dashboard now uses, partitioned by student), and
  the metric cards fetch only the last month of submission timestamps —
  their trend windows never look further back — instead of the full history
  a deadline-day refresh used to re-fold (#1382 item 6). An all-fail
  student still shows "0%" to their instructor, and the roster's values are
  pinned by render tests written against the pre-aggregate loaders.

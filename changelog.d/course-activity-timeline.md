### Added

- **Course activity timeline (#421).** A new Activity tab in the instructor area
  shows who changed what in the active course, newest first: content edits (from
  the assignment version history) and course events (staff added/removed/re-roled,
  assignments created/cloned/deleted, visibility and due-date changes) interleaved
  in one chronological list, filterable by person. Visible to all course staff,
  TAs included, and scoped to the active course — another course's history is
  never reachable from it.
- **Assignment lifecycle events are now audited.** Creating, cloning, deleting,
  changing visibility, and moving a due date each record an audit entry, from the
  browser and from MCP alike. Content versioning deliberately covers only
  content, so these previously had no record anywhere — a deleted assignment left
  no trace it had ever existed.

### Changed

- **`audit_log` gained an indexed `course_id` column**, backfilled from the
  `course_id` key course-scoped events have always carried in their metadata
  JSON. Course-scoped queries are now indexed rather than a full scan over an
  unbounded table, and existing enrollment/staff history appears in the new
  timeline without its call sites being touched.

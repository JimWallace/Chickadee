### Added

- **Class activities, slice 1: leaderboard challenges (#1508).** An assignment can
  now declare an `activity` block with kind `beatTheInstructor` or `bestMetric`.
  A test script reports an unclamped `metric` in its JSON footer beside `score`
  (a ranking number, never credit), the server materialises the best metric per
  student at result ingest, and a new leaderboard page
  (`/:courseCode/:assignmentSlug/leaderboard`) ranks the class by pseudonymous
  handle and chickadee, hidden from students until the instructor publishes it
  (staff always see it, with names). `RecordDimension.highestMetric` crowns the
  class record on the same event, awarded outside the 100% gate. Authored on the
  edit page (a "Class activity" select, locked once a student has submitted, and
  an Activity section with the leaderboard toggle) and through the new MCP
  `set_activity` tool; `get_assignment` and `get_server_info` report the block and
  the kinds. The design note is `docs/class-activities.md`.

### Added

- **Assignment versioning — read and restore over MCP (slices 3-4).** Three new
  agent tools over the content-version history: `list_assignment_versions` (the
  timeline — who edited, when, and what produced it), `get_assignment_version`
  (one past version's manifest and file list, each file marked
  `differsFromCurrent`, plus optionally one file's body — without touching the
  live assignment), and `restore_assignment_version` (put a version's content
  back). Restoring is append-only: it records a new version rather than
  rewinding, so the restore is itself recorded and itself undoable. It restores
  content only — title, due date, and visibility are left alone, so a recovery
  can never reopen an assignment or move a deadline — and, like any content
  edit, it closes the assignment, re-grades existing submissions against the
  restored suite, and re-runs validation. Restore requires the instructor role;
  the two reads require TA.

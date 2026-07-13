### Added

- **Secret reveal tokens.** Each student gets one token per assignment they can
  permanently spend (with a confirmation step) to reveal secret-tier test
  results — itemized rows with status, output, and hints, exactly like public
  tests — across all their past and future submissions on that assignment.
  Off by default; instructors enable it per assignment from the edit page's
  new "Student Options" block or the `update_assignment` MCP tool
  (`secretRevealEnabled`), and course staff can re-grant a spent token from
  the assignment submissions roster. Display-only — grades already span every
  tier, so nothing about grading, CSV export, or BrightSpace sync changes.
  Spends, re-grants, and toggle changes are audit-logged.

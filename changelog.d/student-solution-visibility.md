### Added

- **Post-deadline solution reveal.** A per-assignment "Student Options" policy
  (`solutionVisibility`, default off) lets students view the reference
  solution after the deadline: the notebook page opens it read-personalized
  in the editor, a download route serves upload-only languages, and the
  dashboard, submission page, and notebook toolbar link it once visible. Each
  student's reveal waits for their *own* effective deadline — extensions and
  any slip-day claim they could still make included — so the answer key can
  never be read and then submitted on freshly bought time; an assignment with
  no due date reveals immediately (posted lecture material). Enabling the
  policy is refused while no solution is on file, and a manual re-open
  suppresses the reveal for its duration. Set from the assignment edit page
  or MCP `update_assignment`; reported by `get_assignment`.

### Fixed

- **Release-tier output no longer leaks inside the slip-day claim window.**
  Release output (expected/actual values) used to appear the moment a
  student's effective deadline passed — which, in a slip-day course, is
  exactly when they could still claim a slip day and act on it.
  `releaseVisibilityDeadline` now waits for the end of any slip-day claim
  window the student could still use, on the web view, the results API, and
  the data export alike. Instructors who prefer prompt results may opt out
  per course on the slip-day settings ("Hold release-test output until
  slip-day claims lapse", default on); the solution reveal never honours the
  opt-out.

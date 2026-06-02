### Added

- **Flag dropped students against the LEARN classlist.** A "Check against
  LEARN" button on the instructor Students tab fetches the course's D2L
  classlist and badges enrolled students (and pending "awaiting first login"
  rows) who are no longer registered on LEARN, so the instructor can remove
  stale accounts with the existing per-row delete action. Conservative
  matching — students with no resolvable student ID are reported as
  unverifiable rather than flagged for removal, and only `student` rows are
  checked. The button is hidden unless BrightSpace is configured on the server
  and the course is linked to a LEARN org unit, so it's inert until D2L
  credentials are provisioned.

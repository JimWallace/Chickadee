### Added

- **BrightSpace grade sync now removes a grade when its Chickadee source is
  removed.** When an instructor clears a grade override on a student with no
  submissions, the grade is now removed from the LEARN gradebook on the next
  sync — but **only if Chickadee actually pushed that grade** (there's a
  `success` row in the sync log), so a grade an instructor entered by hand in
  LEARN is never touched. Removals run through a small
  `brightspace_grade_clears` queue and a D2L grade-value `DELETE`; a push queued
  for the same student/assignment always wins over a removal, and a removal is
  skipped if the student's grade source has reappeared (they submitted, or a new
  override was set) before it runs.

### Fixed

- **Preview assignments with a scheduled open date are reachable by staff
  again.** A `.preview` assignment that also carried a future open date
  (`startsAt`) was held closed for *everyone* by the front gate in
  `isAssignmentOpenForUser` — so the instructor who put it in preview to test it
  couldn't open the notebook or submit (worse for browser-graded labs, where no
  upload fallback exists, leaving the row with no actions at all). Staff now
  bypass the future-open-date gate when previewing; the date still governs when
  the assignment auto-publishes to students, and students remain blocked. The
  preview/start-date decision is now a single `AssignmentVisibility.submissionGate`
  helper shared by the submission gate and the dashboard listing.

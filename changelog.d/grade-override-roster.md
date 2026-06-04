### Added

- **Grade override on the per-assignment roster.** The instructor's
  `/instructor/:assignmentID/submissions` page now carries the same set/clear
  grade-override control that the per-student page already had — an inline
  pencil-icon form per student row (override percent + optional note, with a
  Clear button once one is set). The roster already displayed overrides and
  folded them into the median; it can now edit them too. Both sites resolve to
  the same `(test_setup, user)` row through shared `applyGradeOverride` /
  `clearGradeOverride` helpers, so an override set from either page is identical
  and continues to replace the runner-computed grade everywhere (roster median,
  grades CSV, BrightSpace sync, submission view).

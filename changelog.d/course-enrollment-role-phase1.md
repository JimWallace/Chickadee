### Added

- **Per-course role groundwork (multi-course-roles Phase 1).** Each course
  enrollment now carries a `role` (`student` / `instructor`) — the foundation
  for a user being an instructor in one course and a student in another. The
  `AddCourseEnrollmentRole` migration adds the column and backfills it
  behaviour-preservingly from each user's current global role, so this release
  has **no observable behavior change**: nothing reads the per-course role yet
  (the global role still governs what a user can do). See
  `docs/multi-course-roles.md`.

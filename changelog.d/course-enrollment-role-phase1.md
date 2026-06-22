### Added

- **Per-course role groundwork (multi-course-roles Phases 1–2).** Each course
  enrollment now carries a `role` (`student` / `instructor`) — the foundation
  for a user being an instructor in one course and a student in another. A
  migration adds the column and backfills it behaviour-preservingly from each
  user's current global role (Phase 1), and the home/nav read path now derives
  the "Instructor" tab from the *active course's* role rather than the global
  one (Phase 2). **No observable behavior change yet:** every enrollment's role
  mirrors the global role until per-course roles become authorable in a later
  phase. See `docs/multi-course-roles.md`.

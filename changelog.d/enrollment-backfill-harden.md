### Changed

- **`AddCourseEnrollmentRole`'s backfill no longer queries the full enrollment
  model.** It now reads and writes `course_enrollments` with raw SQL over only
  the `id` / `user_id` / `role` columns it touches, instead of a full-model
  `APICourseEnrollment.query().all()`. A full-model query selects every column
  the model *currently* declares, so any column added to `course_enrollments`
  by a later migration would make this backfill fail on a fresh database with
  "no such column" (the roster-readiness columns did exactly that until they
  were reordered ahead of this migration). Behaviour is unchanged — only
  NULL roles are seeded, from each user's global role. No effect on existing
  databases (this migration is already applied there).

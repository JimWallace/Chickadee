### Added

- **Per-course role seeding for new enrollments (multi-course-roles Phase 4a).**
  Every enrollment-creation path now seeds the new enrollment's per-course role
  from the user's current global role (a global instructor/admin becomes a
  per-course instructor, everyone else a student) via a single
  `saveSeededEnrollment` helper. **No observable behavior change** — the
  per-course role still mirrors the global role; this keeps it accurate for new
  enrollments so a later phase can move authorization onto the per-course role
  without dropping anyone's access. See `docs/multi-course-roles.md`.

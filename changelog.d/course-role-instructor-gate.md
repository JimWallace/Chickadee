### Changed

- **Per-course instructor authority (multi-course-roles Phase 4b).** A person
  can now be an instructor in one course and a student in another: the
  `/instructor` section admits a per-course instructor (gated on the caller's
  role *in their active course*), not just a global one, and an instructor or
  admin sets a roster member's per-course role from a dropdown on the Students
  page. The param-taking enrollment endpoints (unenroll, set enrollment mode,
  bulk-enroll, cancel pre-enrollment, set role) check per-course instructor
  access on the course named in the URL, so a per-course instructor can't be
  driven against another course. Existing **global** instructors keep their
  access unchanged — the global-instructor fallback is removed when the global
  role is shrunk in a later phase. See `docs/multi-course-roles.md`.

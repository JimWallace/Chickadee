### Changed

- **Instructor authority is now purely per-course (multi-course-roles Phase 5).**
  Removed the transitional global-instructor fallbacks from the `/instructor`
  gate (`ActiveCourseInstructorMiddleware`), the nav (`isInstructorInActiveCourse`),
  and `requireCourseInstructor`, so a user is treated as an instructor only where
  they hold a per-course `.instructor` enrollment (admins still bypass
  deployment-wide). Existing instructors keep their access via the per-course
  roles seeded by the Phase 1 backfill / Phase 4a seeding.

### Removed

- **Retired `SSO_INSTRUCTOR_USERS`.** SSO no longer maps any identity to a global
  instructor role — only `SSO_ADMIN_USERS` remains; instructors are assigned
  per-course from the course roster. New SSO users default to student. The
  `UserRole.instructor` enum case is kept for decode compatibility; physically
  removing it (a data migration) and removing the global-instructor option from
  the admin user-management UI are deferred follow-ups. See
  `docs/multi-course-roles.md`.

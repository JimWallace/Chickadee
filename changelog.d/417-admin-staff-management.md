### Added

- **Admins can set per-course roles from the course page (#417).** The admin
  course page (`/admin/courses/:id`) now shows each roster member's
  *per-course* role and lets an admin switch it between student and instructor
  inline — the admin-side counterpart of the instructor roster dropdown, so an
  admin can assign a course's staff without first making it their active course.

### Changed

- **Courses can no longer be orphaned of their last instructor (#417).** A new
  `ensureNotLastInstructor` guard blocks a non-admin from unenrolling or
  demoting a course's only instructor; transfer the instructor role first.
  Admins are exempt (they can always re-grant).

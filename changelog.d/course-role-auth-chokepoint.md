### Added

- **Per-course role authorization chokepoint (multi-course-roles Phase 3).**
  `CourseRole` is now ordered (`Comparable`), and `CourseAccessHelpers` gains
  `requireCourseRole(caller:courseID:atLeast:db:)` — the role-aware
  generalization of the existing enrollment check, which becomes its `.student`
  case. Authorization is purely per-course (admin bypass only). **No observable
  behavior change:** production callers use the `.student` bar, and every
  enrolled user is at least a student. See `docs/multi-course-roles.md`.

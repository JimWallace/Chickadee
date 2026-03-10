# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [0.2.0] - 2026-03-10

### Changed

- **Breaking (fresh DB required):** Consolidated all patch migrations into their original `Create*` files. Migration count reduced from 11 to 8; no patch migrations remain.
  - `AddUserProfileFields` and `AddUserSSOFields` folded into `CreateUsers`.
  - `AddCourseToAssignments` eliminated; `course_id` column now in `CreateTestSetups` and `CreateAssignments` from the start.
  - `AddCourses` renamed to `CreateCourses`; `AddCourseEnrollments` renamed to `CreateCourseEnrollments`.
- **Schema hardening** (closes #84):
  - `course_id` is now `NOT NULL` with a FK to `courses(id)` on `test_setups` and `assignments`.
  - `course_enrollments.user_id` now has `ON DELETE CASCADE` FK to `users(id)`.
  - `courses(code)` now has a `UNIQUE` constraint.
  - Added four missing indexes: `idx_assignments_course_id`, `idx_test_setups_course_id`, `idx_course_enrollments_course_id`, `idx_course_enrollments_user_id`.
- `APITestSetup.courseID` and `APIAssignment.courseID` are no longer optional; both models require a course.
- `saveNewAssignment` now resolves the instructor's active course and assigns it to newly created test setups and assignments.
- `POST /api/v1/testsetups` now requires a `courseID` field in the multipart form.
- Migration order resequenced to respect FK dependencies (`CreateCourses` before `CreateTestSetups`).

## [0.1.0] - 2026-02-24

### Added

- Baseline database schema now includes canonical fields and foreign key constraints.
- SQLite foreign key enforcement and WAL journaling at startup.
- Performance indexes for high-frequency submission/result/user queries.
- Version scaffold:
  - `VERSION` file.
  - Shared `Core` version constant (`ChickadeeVersion.current`).
  - Runner `--version` support.

### Changed

- Migration chain simplified to canonical create migrations plus index migration.
- API and worker startup now consistently report/consume project version metadata.

### Removed

- Legacy additive migrations that were made obsolete by the canonical baseline schema.

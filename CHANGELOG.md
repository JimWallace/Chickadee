# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

## [0.4.0] - 2026-03-15

### Added

- **Test dependency trees**: test suites can declare `dependsOn` — a list of prerequisite script names. If a prerequisite does not pass, all dependent tests are automatically recorded as `fail` with a "Skipped: prerequisite '…' did not pass" message. Applies to both the server-side shell runner and the browser-side Pyodide runner. The manifest is validated for reference integrity and cycles at upload time; entries are topologically sorted before serialization so the runner's linear pass always sees parents before children.
- **Tree UI for assignment files**: the file/test configuration panel on the assignment create and edit pages is now a drag-and-drop dependency tree. Drop a test onto the middle of another root test to make it a child (dependent); drop onto the bottom strip to remove the dependency. Maximum one level of nesting enforced in the UI.
- **Docker Compose deployment**: multi-stage `Dockerfile` compiles both binaries with `--static-swift-stdlib` (no Swift toolchain required on the host); `docker-compose.yml` orchestrates `server`, `runner`, and an optional `nginx` service with named volumes for persistence. `deploy/docker-entrypoint.sh` syncs static assets into the data volume on each startup so template and JupyterLite updates are always picked up on redeploy.
- `deploy/nginx-docker.conf` — Docker-specific nginx config with COOP/COEP headers and a commented-out HTTPS server block ready for certbot.

### Changed

- `TestSuiteEntry` gains `dependsOn: [String]` (default `[]`); existing manifests decode without change (backward-compatible).
- `.env.example` revised: `RUNNER_SHARED_SECRET` documented as required; OIDC vars updated with clearer placeholders.
- `deploy/README.md` restructured: Docker Compose quick-start added at the top; VM/systemd instructions preserved below.
- `README.md` revised: deployment section added, test dependency trees documented, auth description corrected to reflect full SSO implementation.
- `CLAUDE.md` updated: SSO marked complete; Docker deployment marked complete; next-work list updated.

## [0.3.0] - 2026-03-10

### Added

- **Course bundle export/import** (closes #68): instructors can export a course as a `.chickadee` zip bundle containing all assignments and test setups, and re-import it on another instance.
- Admin course detail page with bulk CSV enroll, unenroll, and per-student assignment view.
- Admin users table with course filter.
- Archive/unarchive course action with confirmation dialog.
- Assignment count per course displayed in the admin courses table.

### Changed

- Admin courses section reworked: course list and create/edit pages consolidated into a single `admin-course.leaf` template with an `isNew` flag.
- Edit course falls back to existing values when submitted with blank fields.
- Removed dead `GET /assignments/new/details` route (was an immediate redirect; template deleted).
- Removed abandoned `BuildStrategy` / `PythonBuildStrategy` scaffolding (superseded by shell-script runner architecture).

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

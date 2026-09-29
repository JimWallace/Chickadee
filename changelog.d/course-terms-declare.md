### Added

- **Course year and term on the admin forms.** A new course must declare its year and term (Winter, Spring or Fall), and an admin can set the term of an existing course on its edit page. Course bundles carry the term. Course tabs, the instructor switcher, the admin tables and the enrollment, account and LTI pages show it, and course lists sort newest term first. See `docs/course-terms.md`.

### Fixed

- **Duplicate course codes are reported.** The course create form reports an active duplicate code, and the course page now shows the duplicate-code error that the edit form always sent. The bundle import no longer passes its duplicate check on an archived course and then fails on the database index.

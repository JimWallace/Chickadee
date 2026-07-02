### Changed

- **Roles naming cleanup (#1127).** The `/instructor` area gate is renamed
  `ActiveCourseStaffMiddleware` (it has admitted TAs since the #417 Slice-E
  rung — it is a staff gate), and the nav context properties follow:
  `isStaffInActiveCourse`, `staffCourses`, `isStaffAnywhere`, `showStaffTabs`,
  `primaryStaffCourse`. The one-line `requireCourseInstructor` alias was
  inlined into its last caller and deleted. `instructorBulkEnrollCSV`'s manual
  archived-course guard is gone — `requireCourseWriteAccess` is the single
  statement of that rule. Also: the support-file extraction warning goes
  through the logging system instead of `print`, and `resolveCourseAndStudent`
  no longer filters on a `student.id ?? UUID()` sentinel.

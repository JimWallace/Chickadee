### Added

- **TA per-course role (#417 Slice E).** `CourseRole` gains a `ta` rung between
  `student` and `instructor`. A TA may enter the instructor area and do the
  teaching work — view all students' submissions, retest, and edit assignments,
  tests, suites, pattern families, notebook checks, global/section inputs,
  datasets, achievements, the starter notebook and reference solution — but
  **cannot** manage enrollment, set deadlines/extensions, archive, delete
  assignments/setups, clone, create new assignments, or change course staff
  (those stay `instructor`-only). Authority is purely per-course: a TA whose
  deployment role is `student` still gets full TA access in the courses they
  assist. Mechanically, `ActiveCourseInstructorMiddleware` now admits
  `role >= .ta` into the `/instructor` area, the content-editor write loader
  (`loadAssignmentAndSetupForWrite`) defaults to a `.ta` floor while the
  assignment-lifecycle loader (`loadAssignmentForWrite`) stays `.instructor`
  (the per-student grading actions pass `.ta`), the per-student-page handlers
  gate on a per-course staff check instead of the old global `isInstructor`,
  and the nav lights the Instructor surface for staff. The roster role dropdowns
  (admin course page + instructor Students tab) offer **Student / TA /
  Instructor**, and the last-instructor guard still blocks demoting a course's
  only instructor (now including demotion to TA).

### Notes

- A handful of borderline actions were kept at the stricter `instructor` floor
  (open/close/status, reorder, BrightSpace grade-item config, REST
  test-setup upload + notebook-save, new-assignment drafts); these can be
  relaxed to `.ta` later if desired. The MCP surface remains enrollment-gated
  (it does not yet read the per-course role), so TA-vs-instructor distinctions
  there are a separate follow-up.

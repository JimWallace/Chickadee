### Changed

- **Test course builders use the shared fixture.** Ten suites built and saved an `APICourse` by hand, and the three archived-course route suites each copied one course-and-assignment builder. They now call `makeTestCourse`, and the archived suites share `makeCourseWithAssignment` in `AssignmentRoutesHelpers.swift`. (#2366)

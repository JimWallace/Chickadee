### Changed

- **Tests sign in as a student or a course TA through shared helpers.** Twelve suites carried a private `loginAsStudent` and two carried the same `loginAsTA`, each with its own copy of the enrolment upsert. They now use `loginAsStudent(_:on:)` and `loginAsCourseTA(_:on:)` in `TestLogin.swift`, and `enrollAsTestInstructor` is one case of a new `enrollInTestCourse(role:)`. (#2364)

### Changed

- **One helper signs in a per-course test instructor (#1952).**
  `loginAsCourseInstructor(username:courseCode:on:)` signs in an instructor
  and enrols them as course staff through `enrollAsTestInstructor`.
  `arLoginAsInstructor` no longer repeats that upsert line for line, and five
  suites lose a private copy of the same two steps.

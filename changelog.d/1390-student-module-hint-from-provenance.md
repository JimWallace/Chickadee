### Fixed

- **A zip submission to a C++ (or Java or Racket) assignment is graded against
  the student's own file again.** An archive upload carries no filename, so no
  `.chickadee_student_module` hint was written, and the generated C++ wrapper
  fell back to globbing `*.cpp` in the merged workspace — where it took the
  alphabetically-first candidate and compiled the instructor's `helpers.cpp`
  instead of the student's `solution.cpp`, reporting the student's correct work
  as a missing function. The hint is now derived from what the *submission
  directory* held, before the merge, which is the only point at which the
  student's files can still be told apart from the instructor's.

### Security

- **A C++ submission that calls `exit(0)` no longer passes every test.** C++ was
  the only language with no exit guard: `ck::passed` is a bare `std::exit(0)`
  and the wrapper `exec`'d the binary, so a student's own `exit(0)` — in an
  error path, which is where an intro submission puts one — exited with status 0
  and every case in the assignment reported a silent pass with no verdict at
  all. The C++ runtime now prints the sentinel line every other compiled
  language's runtime prints, and the wrapper refuses a run that did not emit it.
  The ceiling is stated in both files: student code and the grading runtime
  share one process, so a submission that prints the sentinel itself and exits
  is still a pass — a deliberate act, not the error-path `exit(0)` this catches,
  and the same limit Java's sentinel has.

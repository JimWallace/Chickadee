### Fixed

- **A Java submission whose method is not `static` (or is `private`) now fails
  the existence guard with a message saying so.** The guard matched on name
  alone, so it passed — and then every scored case failed to compile with
  "non-static method cannot be referenced from a static context", reporting
  `error`. The one test whose job is to explain the problem said everything was
  fine.
- **A missing C++ submission is a graded failure, not a harness error.** The
  0-point existence guard reported `error` where Java reported `fail` for the
  same student state, because C++'s no-submission check ran before the compile
  step that Java routed through.
- **Compiler warnings no longer appear in a passing test's output.** Both
  wrappers sent the build stream straight to stderr, so javac's "unchecked or
  unsafe operations" note and any g++ warning rode a *successful* compile into
  the student's `longResult`. The build log is now emitted only when the compile
  fails.
- **A C++ or Java harness error no longer borrows the student's last line as its
  summary.** Neither `errored` emitted a `shortResult` footer, so the shell
  contract fell back to the last stdout line — a student's stray `print` became
  the one-line summary of, for example, a failing reference implementation.

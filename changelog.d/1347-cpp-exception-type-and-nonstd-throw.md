### Fixed

- **A C++ `exceptionExpected` case now matches the exception's type, not only
  its message.** The save-time validator asks authors to name the exception
  class, and C++ compared the authored text against `what()` alone — so a
  student correctly throwing `std::invalid_argument("n must be positive")`
  against an authored `invalid_argument` was marked "wrong error raised". The
  type name is folded into the reported text, so the "got:" line now names it
  too. Java and Python already matched on type.
- **A C++ submission that throws something other than a `std::exception` is a
  graded failure instead of a crash.** `throw "text";` and `throw -1;` — what an
  intro course teaches before `<stdexcept>` — escaped the generated handler and
  aborted the process, which the runner reported as `error` with a raw
  `terminate called after throwing` on stderr. The same submission in Java has
  always been a clean fail.

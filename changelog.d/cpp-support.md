### Added

- **C++ is a full assignment language — the first with no editor kernel.**
  `AssignmentLanguage` is now `.python | .r | .lua | .octave | .cpp`. C++
  assignments are upload-only (`submissionMode: "uploadOnly"`, enforced on
  every authoring surface) and grade exclusively on the native worker with
  the course's real g++ toolchain — no xeus kernel is vendored, deliberately:
  a browser kernel would grade a different compiler than the course teaches
  (docs/cpp-support.md records the two-C++s decision). A generated case is a
  POSIX shell wrapper that compiles one translation unit (the injected
  template runtime `test_runtime.hpp`, optionally `_ck_inputs.hpp`, then the
  student's file with `main` renamed so program-style submissions still
  expose their functions) and runs the binary under the original
  shell-script contract — no per-language build strategy enters Swift, and
  per-test compile is ~0.65 s at -O0, measured. All eight pattern-family
  kinds render and execute, including `performanceThreshold` (supportable
  precisely because C++ is native-only; its wrapper compiles -O2) and
  `returnTypeCheck` (static-type matching via decltype, no RTTI). Notebook
  checks are refused categorically — there is no notebook workflow to check.
  Literals never guess a type: single-kind containers render explicitly
  typed, and JSON null, mixed arrays, and nested containers are refused at
  save time with named reasons. Personalization `=` expressions are C++,
  evaluated by a compile-and-run driver (~0.3 s) sharing the same Horner
  seed fold as every other language, delivered as typed
  `inline const auto` definitions in `_ck_inputs.hpp`. g++ rides both
  images, runners advertise it via the capability probe, and the upload
  form's accept hint now includes `.cpp`/`.h`/`.hpp` from the language
  table.

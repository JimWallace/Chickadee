### Added

- **Java is the seventh assignment language.** `AssignmentLanguage.java` —
  upload-only and native-worker-only like C++ and Racket, with no editor kernel
  (the request was explicitly for no REPL or notebook workflow, and a browser
  kernel would grade a different toolchain than the course's `javac`). All nine
  pattern-family kinds render and execute; per-student `=` expressions evaluate
  through a `javac`-based server driver sharing the same Horner seed fold as
  every other language; notebook checks are refused categorically at save time
  with a stated reason. Generated cases are POSIX shell wrappers that compile
  with `javac` and run with `java` (~0.6 s per test, measured), so no
  per-language build strategy enters Swift. A JDK (`default-jdk`) is now on the
  application and CI images.

### Changed

- **The `.cpp`-shaped forks in language handling are now derived.** Six places
  asked `language == .cpp` when they meant "does this language's generated case
  carry no language signal?" — a question Java answers the same way. They read
  `LanguageDescriptor.generatesLanguagelessWrapper` instead, and the
  `generatedScriptExtension` uniqueness pin exempts exactly those languages
  rather than naming C++.

### Fixed

- **A notebook check on any assignment could be refused as colliding with
  itself.** The generated-filename collision scan flat-mapped names across every
  language without deduplicating, so as soon as two languages shared a generated
  extension one check produced the same filename twice and tripped the
  duplicate-name guard. Found by adding the second such language.
- **`differentialReferenceName` could produce an illegal identifier.** It
  interpolated the family's function name directly, which is a qualified
  `Class.method` for Java — yielding `ck_ref_Solution.f`, a name that no
  generated test could compile and no instructor could define, in both the
  renderer and the save-time validator that checks for it. Dots are now
  sanitized to underscores.

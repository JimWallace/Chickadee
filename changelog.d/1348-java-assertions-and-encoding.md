### Fixed

- **Java assertions now run in generated tests.** `javaGuarded` documents
  catching a student's `assert`, but the JVM was launched without `-ea`, so
  assertions were disabled and a submission proceeded with its precondition
  unchecked — the opposite of what the comment promised.
- **A Java verdict message keeps its non-ASCII characters.** `System.out` uses
  the host's `native.encoding` (ASCII on a container with no `LANG`), so a
  failure quoting a student's accented output reached the runner with `?` in
  place of every non-ASCII character. Verdicts are written through an explicit
  UTF-8 stream on the real stdout. Comparisons were never affected.
- **`javac` is given `-encoding UTF-8`** in the personalization driver as well
  as the test wrappers. Generated Java source is unconditionally non-ASCII, and
  while javac defaults to UTF-8 on JDK 18+ regardless of locale, the repo
  supports Java 11+, where it does not.

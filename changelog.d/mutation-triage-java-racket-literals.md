### Added

- **The Java and Racket literal renderers now have tests.** `javaLiteral`,
  `javaDeclaredType` and `racketLiteral` appeared under `Sources/` and nowhere
  under `Tests/`, so the 2026-08-19 mutation sweep reported all 23 of their
  mutants as survivors — the answer it must give for code no test references.
  `JSONValueJavaLiteralTests` and `JSONValueRacketLiteralTests` pin the
  behaviours those mutants poke at: the `int`/`long` boundary exactly at
  `Int32.max` and `Int32.min` (where a wrong answer is a compile error in the
  generated test, not a wrong mark), integral and exponential doubles keeping
  exactly one decimal point, sorted object keys, `Arrays.asList` admitting
  nulls, `(list)` versus `(list …)`, and control-character escaping — Java's in
  three-digit octal, never a backslash-u escape the lexer would eat.
  `JavaLiteralTypingTests`, which `JSONValueJavaLiteral.swift`'s own doc comment
  already cited as pinning the literal-to-declared-type round trip, did not
  exist; it does now, under the name the doc already used.

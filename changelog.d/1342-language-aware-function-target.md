### Fixed

- **No Java or Racket pattern family could be saved at all.** A family's
  `functionName` was validated with `isValidPythonIdentifier` on *every*
  assignment, whatever its language. Java has no free functions, so its target
  is a qualified `Class.method` — and the dot fails Python's rules, while
  `docs/java-support.md` requires the qualified form, making the two rules
  mutually exclusive. Racket's idiomatic `bmi-category` fails on the hyphen. The
  refusal named Python on assignments with no Python in them.

  It stayed invisible because both renderers were written believing the check
  was already language-aware and so neither shouts: `PatternFamilyRendererJava`
  calls its unqualified branch "unreachable through authoring", and the Racket
  renderer quietly sanitizes an invalid name to `ck-invalid-name`. The check now
  dispatches on the assignment's declared language and delegates each arm to the
  grammar that language's own renderer uses, so what validation accepts and what
  rendering can emit cannot drift. The four languages that share Python's rule
  keep their exact previous behaviour.

  Found by authoring the first real Java assignment rather than by any test,
  which is the note worth keeping: the language arc shipped seven languages and
  five sample assignments, and the two languages with no sample are exactly the
  two that were broken.

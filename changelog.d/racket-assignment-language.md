### Added

- **Racket is the sixth assignment language.** `AssignmentLanguage.racket`
  covers the courses Waterloo's first-year CS stream actually runs — CS 135 and
  CS 115 (`#lang htdp/bsl`) and CS 136 (`#lang racket`) — with all eight pattern
  kinds rendering and executing. It is upload-only like C++, because no
  Scheme-family kernel exists on `emscripten-forge-4x` to vendor; unlike C++
  that answer is contingent rather than principled, so a kernel appearing is a
  reason to revisit it. Notebook checks are refused categorically for the same
  structural reason as C++ (no submitted notebook exists). `racket` is on the
  server, runner and CI images; the Debian package carries the HtDP
  teaching-language collections, which is a requirement and not a bonus.

  Four things were measured before any Swift was written, each because the
  obvious spelling fails silently:

  - A teaching-language module **exports nothing**, so a generated test cannot
    `require` the submission. Tests load it with `dynamic-require` +
    `module->namespace`.
  - Definedness must ask `namespace-mapped-symbols`;
    `namespace-variable-value` reports a perfectly good BSL binding as missing.
  - Calls must evaluate an **application form**, never a bare identifier — BSL
    rejects a function reference outside operator position.
  - Arguments must be **bound into the namespace and passed by name**. Quoting
    is the natural spelling and BSL refuses it (`(quote (1 2 3))` is an error),
    which would have broken exactly the list-valued arguments a CS 135
    assignment is made of.

  The payoff is that one rendered test grades both dialects unchanged, which
  `PatternFamilyRendererRacketTests` pins by running every kind against each.
  Numeric comparison uses `=` rather than `equal?` because BSL reads `18.5` as
  the exact rational `37/2`, and `equal?` would mark a correct student wrong.

### Changed

- **`existenceGuard` builds its `GeneratedScript` once.** Every per-language arm
  constructed an identical value around a different source string; the shared
  construction is hoisted and Python's bytes moved to a helper unchanged (the
  goldens verify). A seventh language is now one line there rather than
  thirteen.

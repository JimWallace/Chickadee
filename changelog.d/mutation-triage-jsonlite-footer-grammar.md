### Added

- **The result-footer parser is now tested for the grammar it accepts, not just
  the numbers it computes.** RunnerCore's `JSONLite` is a general JSON parser,
  but the footer contract only names `shortResult` and `score`, so it had been
  exercised on those two field types alone — leaving arrays, `null`, booleans,
  `\u` escapes, interior tabs and trailing-content rejection unpinned. The
  2026-08-19 sweep reported ten surviving mutants there and killed only the two
  in number parsing. `JSONFooterGrammarTests` covers the rest, each test naming
  the mutation it kills. One mutant is deliberately left alive with its reason
  recorded: flipping `parseNumber`'s `if current == "-"` to `!=` is an
  equivalent mutant, because the loop that follows accepts `-` as well, so the
  slice handed to `parseDoubleLiteral` is unchanged for every input that can
  reach it.

### Fixed

- **The sweep no longer reports mutations Muter never actually made.** Nine of
  run 32265903112's 75 survivors were `SwapTernary` mutations emitted
  *identical to the original* apart from whitespace — the branches came back
  unswapped. These are not phantoms (the schema really was inserted, so the
  existing guard-based filter passes them) and not equivalent mutants (the code
  is textually unchanged, not merely behaviourally so); nothing can kill them,
  and they read exactly like real holes. Recording each mutation's `original`
  made them detectable for the first time, and `report.py` now quarantines them
  into their own section beside the phantoms. Two had already been mistaken for
  leftover gaps in a file that had just been covered properly.

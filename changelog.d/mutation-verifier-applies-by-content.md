### Fixed

- **The mutation verifier could report a real gap as already covered.**
  `verify-survivor.py` applied a recorded mutation by replacing Muter's reported
  line, but Muter records the *enclosing statement* while its line and column
  point at one operator inside it — positions `report.py` already calls
  known-wrong. Measured across run 32255707345, the reported line held the whole
  mutated statement for 15 of 84 candidates; for the other 69 the edit deleted a
  `case` label, pasted an expression beside the half already above it, or
  spliced in text opening with `//`. Those edits do not fail honestly, they fail
  to compile — and `swift test` going red was read as `KILLED`, which the triage
  protocol spells "already covered, do not write a test". `report.py` now
  records each mutation's `original` (the trailing `else` of Muter's schema
  chain) so the edit is an exact textual swap needing no position at all; the
  verifier refuses to apply anything it cannot place faithfully, never calls a
  build failure a kill, and restores the file if it is interrupted mid-run.
  Records written before this carry no `original` and are now honestly reported
  `UNVERIFIABLE` rather than silently mis-applied.

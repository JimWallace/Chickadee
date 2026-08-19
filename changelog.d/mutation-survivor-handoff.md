### Added

- **Mutation survivors are now reproducible, and there is a protocol for acting
  on them.** A survivor used to be recorded as a file, a line and an operator
  name — not enough to reproduce it, since one line can carry several mutable
  sub-expressions and the operator says nothing about what replaced which. The
  run record now carries the mutation Muter actually inserted, lifted from the
  schemata in the mutated copy, and `Tools/mutation/verify-survivor.py` replays
  it against the sweep's own suite. Run it before writing a test (expect the
  mutant to survive; anything else means the finding is stale) and after
  (expect it killed, by the test just added). `docs/mutation-triage.md` is the
  protocol, including the three legitimate outcomes — one of which is "no test,
  here is why".

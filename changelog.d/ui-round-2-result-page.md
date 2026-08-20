### Changed

- **Hidden tests are itemized without being revealed.** A student used to see
  one aggregate line per section ("1 passed, 1 failed") for the secret tier, and
  could not tell how many points had moved or how many things had broken. Each
  hidden test now gets its own masked row — "hidden test 1…N" carrying its real
  mark and its points — under a header stating the stake ("4 hidden tests · 4 of
  8 points"). Names, messages, output, hints and blocker names stay hidden until
  the reveal token is spent, and the delta arrows are withheld too: the number is
  positional within one render, so an arrow against it would not correlate across
  attempts. No new data — `secretOutcomes` already existed.
- **The result page leads with the grade.** The percentage is the largest thing
  on the page, with the pass/fail/error/timeout counts as tiles beneath it, and
  non-passing output collapsed into `<details>` (so five failures stop being a
  wall of stderr) rather than standing permanently open.

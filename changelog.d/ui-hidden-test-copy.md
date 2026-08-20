### Changed

- **A hidden test's result is reduced to a case count, and the block explains
  itself in one line.** The short result was passed through verbatim, and a
  short result is whatever the instructor's script printed last — so a suite
  printing "expected 42, got 7" leaked the expectation of a test whose whole
  point is being hidden. It now goes through an allowlist of case-count shapes
  and degrades to "passed" / "did not pass" otherwise. The block's explanation
  moves from a footnote into its header as a single phrase.

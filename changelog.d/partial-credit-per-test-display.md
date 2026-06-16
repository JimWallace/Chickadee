### Added

- **Per-test partial credit is now shown to students (#548).** When a test
  earned a fraction of its points (a script that emitted an explicit `score`
  in its stdout footer, `0 < score < 1`), the submission results table now
  renders the earned fraction next to the result mark — e.g. `1.5 / 2 pts` —
  instead of only the test weight. Full credit and no credit keep the plain
  weight label. Parsing, storage, and grade rollup (`earnedPoints = Σ points ×
  score`) were already wired; this surfaces the per-test breakdown in the UI.

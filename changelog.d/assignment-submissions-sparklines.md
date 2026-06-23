### Added

- **Distribution sparklines on the assignment-submissions statistics.** The
  instructor `/instructor/:assignmentID/submissions` stat cards now draw a
  compact sparkline behind three of their headline numbers: the grade
  distribution (ten 10-point bins) under *Median Grade*, the
  attempts-per-student distribution (1–6+) under *Avg Attempts/Student*, and
  daily submissions over the last 14 days (Waterloo days) under *Submissions
  (24h)*. Bars are rendered server-side from pre-normalized heights — reusing
  the existing `.diagnostic-spark` styling, no JavaScript or polling endpoint —
  so they work without scripts; per-bar tooltips and a screen-reader caption
  describe each chart. Cards with no distribution stay plain numbers, and the
  sparkline is omitted entirely when an assignment has no submissions yet.

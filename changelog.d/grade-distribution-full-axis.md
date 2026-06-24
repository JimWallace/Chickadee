### Fixed

- **Distribution sparklines now show their full axis.** Empty buckets in the
  assignment-submissions distribution charts (grade spread, attempts) rendered
  fully transparent, so a clustered grade distribution looked like it only had
  the buckets that contained students. Empty buckets now draw a faint baseline
  tick, so the grade histogram always reads as a fixed 0–100% range (ten 10%
  buckets) regardless of how the grades cluster.

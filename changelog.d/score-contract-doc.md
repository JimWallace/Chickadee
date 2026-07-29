### Changed

- **Test-script contract documents partial credit (#548).** The `CLAUDE.md`
  stdout-footer section still described `score` as "reserved for partial credit
  (not yet used)", which has been stale since v0.4.444 wired the field through
  interpretation, grade rollup, and the student results table. It now states the
  real semantics: a `Double` clamped to `0...1`, contributing `points × score`
  to `earnedPoints`, orthogonal to the exit code, defaulting to full credit on a
  pass and none otherwise when no `score` is emitted. Documentation only — no
  behaviour change.

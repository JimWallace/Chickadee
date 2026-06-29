### Fixed

- **BrightSpace grade sync no longer fails every result-driven push.** The
  v0.4.567 "highest grade wins" refactor (#1085) left `bestGradeForStudent`
  requiring a manifest suite-total with no fallback and reconstructing points
  from an integer percent, so every worker/browser-result push threw
  `missingPoints` (and lost precision, e.g. 6/7 → 8.6 instead of 8.57) — turning
  the whole `BrightSpaceGradeSyncTests` suite red. The sweep now selects the best
  result across all sources (browser or worker — a higher browser grade is never
  displaced by a lower worker re-grade) and pushes its exact points, falling back
  to the result's own recorded total when the manifest carries no per-suite
  points.

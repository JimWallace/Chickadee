### Added

- **Datasets: train/test split design + grader-only file foundation.** Documents
  train/test splits in `docs/datasets.md` as two composable blocks — a
  per-student served sample plus a *reserved grader-only file* (a holdout served
  to no student, present only in the worker grader) — and adds the inert
  `TestProperties.graderOnlyFiles` manifest marker for it. Enforcement
  (withholding the file from every student-facing path) and authoring land in
  follow-ups; the marker does nothing on its own yet.

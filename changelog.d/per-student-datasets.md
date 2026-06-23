### Added

- **Per-student datasets (foundation).** Groundwork for marking a bundled
  support file as a per-student dataset. A `DatasetSpec` manifest type and a
  deterministic, seed-driven `DatasetMaterializer` (row sampling) in Core let
  each student receive a reproducible slice of a shared data file; the slice is
  resolved once server-side so the editor and the grader agree byte-for-byte.
  Wiring into grading delivery and the suite editor follows — see
  `docs/datasets.md` for the design and the HLTH 230 Assignment 4 plan.

### Added

- **Per-student datasets: worker grading delivery.** When an assignment's
  manifest declares datasets, the server now resolves each student's
  deterministic slice (via `DatasetResolver` + the seed) and ships the bytes in
  the worker job payload; the runner writes them into the grading workspace,
  overwriting the instructor's source pool so a student's scripts grade against
  only their slice. A strict no-op for assignments without datasets. Editor
  delivery and the authoring UI follow — see `docs/datasets.md`.

### Changed

- **The runner's job pipeline is split by phase.** `RunnerDaemon+JobProcessing.swift` (1,037 lines) is now five files: the pipeline, the workspace, the prepare phase, the execute phase and the report phase. The per-student file writes (`materializePersonalizedFiles`) and the collection fold (`makeCollection`) are free functions with their own tests. Two unused fields on `JobPreparedWorkspace` are gone. Grading does not change (#1799).

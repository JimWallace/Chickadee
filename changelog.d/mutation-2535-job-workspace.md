### Changed

- **Mutation triage (#2535): the per-job workspace helpers have tests.** The workspace setup and teardown in `JobWorkspace.swift` are `nonisolated`, and `JobWorkspaceLifecycleTests` pins the disk floor, the stage timings, the workdir removal and the two capacity log events.

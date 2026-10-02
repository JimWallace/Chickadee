### Changed

- **`RunnerResult.swift` is deleted.** It described a JSON document that runner scripts write and the worker parses, which is the runner JSON protocol CLAUDE.md forbids and which nothing has ever used: `RunnerResult` and `RunnerOutcome` had no reference outside one Core test block, now gone with them (#1722).

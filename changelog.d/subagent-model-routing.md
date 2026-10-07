### Added

- **Claude Code subagents and model routing.** The project settings select the `opusplan` model. Four report-only subagents run the tests (`test-runner`), the UI guards (`ui-guard`), the format-lint guards (`lint-guard`) and a review of the uncommitted diff (`diff-reviewer`). Permission rules allow the read-only check commands, ask before a test file changes, and deny edits to the release-managed and vendored files.

### Changed

- **Four page view models are private to their route files, and `SubmitChips` moves to a context file (#2113).** `StudentRowsFragmentContext`, `LeaderboardPresentContext`, `SlipDayConfirmContext` and `InstructorNewTermContext` have no reader outside their file. `SubmitChips` is read by the upload form and the GitHub submit page, so it now lives in `GitHubSubmitContext.swift`. Placement only.

### Fixed

- **Runner start-up refusals are pinned by a test.** The runner now reports an invalid `--api-base-url` and a missing runner secret through one helper, `WorkerCommand.startupFailure`. A test checks that the helper writes the message and returns the failure exit code.

### Changed

- **Tests for the live-session window.** `LiveSessionWindow` and the window storage in `ClassActivity` now have tests in `CoreTests`. The weekly mutation sweep skips `APITests`, so these operators had no coverage there. `isCoverageClassGoal` also has tests for its two-part check.

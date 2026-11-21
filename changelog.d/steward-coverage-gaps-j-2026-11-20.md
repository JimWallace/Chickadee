### Added

- **Tests for diagnostics failure paths and the leaderboard builders.** New suites check that a failed diagnostics write logs one warning with no student identifier, that the queue-depth fallback counts what the SQL count does, and that the leaderboard ranks highest first with ties, hides names from students, and shows a superseded bracket and a union viewer with no submission correctly.

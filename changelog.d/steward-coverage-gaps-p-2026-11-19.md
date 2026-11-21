### Changed

- **Tests for the Swift fallbacks of the student submission aggregates.** A new suite reaches the four non-SQL fallbacks of the dashboard and roster loaders (latest submission and attempt count per setup and per student, and the best grade per setup and per student) through a database wrapper that is not an SQL database. It checks the latest-pick order and its tie-break, the scoping to student attempts, the 0% rule of each fold, the 99% cap on a partial mark, and that each fallback gives the same answer as the SQL path. No product code changed.

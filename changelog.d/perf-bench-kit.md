### Added

- **A re-runnable performance bench and a weekly check.** `Tools/perf-bench/` builds a course-scale data set (300 students, 18,000 submissions, 400,000 request metrics) on a fresh database through the real routes, measures the statements, rows and time of each main page, and runs the runner-claim backlog scenarios. `weekly.sh` does it all and prints one summary. `docs/database-performance.md` holds the v0.5.876 baseline and the rule for what counts as a regression.

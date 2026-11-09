### Added

- **Statement budgets for the hot pages.** `StatementBudgetTests` counts the SQL statements that each hot page and the idle runner poll send, and holds each at an exact budget, so a pull request that adds a query fails and one that removes a query lowers the budget. It also measures each page on a small and a larger course, and fails on a count that grows with the data (an N+1). See `docs/performance-program.md`.
- **The weekly performance task.** `Tools/perf-bench/weekly-task.md` is the procedure a scheduled task follows each week: a read-only production snapshot through the admin MCP, then `Tools/perf-bench/weekly.sh`, written up as a pull request to the new `docs/perf-log.md`. The plan also covers re-testing a whole assignment, the burst most likely to flood the runners.

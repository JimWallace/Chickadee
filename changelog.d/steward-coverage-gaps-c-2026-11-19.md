### Changed

- **Tests for the unclaimable-jobs read and the database statement statistics.** New suites cover how the unclaimable-jobs health rule reads its jobs (pending only, the minimum wait, the retest time, the stored runner profiles, the assignment requirement, and the names of the blocked setups), and how `QueryStatistics` checks for pg_stat_statements, creates the extension at startup, and reads the statement rows, totals and reset time. No product code changed.

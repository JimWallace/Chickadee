### Fixed

- **Course-wide result queries no longer bind one parameter per submission (#2764).** The LEARN tab summary and "Sync now" now join results to submissions and filter by the course's test setups. "Sync now" also filters the errored rows in SQL. Course export and the retention purge split their submission-ID lists into chunks. Before, a course with more than 65,535 submissions made these four actions fail on PostgreSQL. The SQLite that sqlite-nio compiles allows 250,000 parameters, so it failed only at that size.

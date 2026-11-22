### Changed

- **Tests for the success path of the admin `get_query_stats` tool.** The scripted catalog database and the stats-schema fixture moved from the `QueryStatistics` tests into a shared test file. A new `useScriptedCatalog` helper makes the scripted database the one that a request reads, so the tool's ready path (totals, order, limit, share of total, reset date, hidden-text note) and its two unavailable states now run on every test database.

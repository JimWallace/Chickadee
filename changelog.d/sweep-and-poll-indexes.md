### Fixed

- **Indexes for the periodic sweeps, the leaderboard poll and the push webhook.** The AGS grade-sync sweep (every 60 seconds), the hourly LTI reaper, the achievement sweep's corpus-run read, the union leaderboard body polled every 5 seconds, the tournament scheduler and the GitHub push webhook each scanned a table whose only index was the row's unique identity. `CreateSweepAndPollIndexes` adds the nine indexes those filters lead on (#1800, #1801, #1802, #1803, #1804).

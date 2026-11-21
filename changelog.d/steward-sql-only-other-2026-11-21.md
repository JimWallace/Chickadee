### Removed

- **Non-SQL fallbacks in the remaining reads and writes.** The instructor submitter counts, grades export and submission timestamps, the BrightSpace sync flags, the LTI grade sync queue and the session user lookup no longer have a Swift path for a database without SQL. The single-use burn, the MCP upload claim and the refresh token rotation no longer answer "won" on such a database; they now throw.

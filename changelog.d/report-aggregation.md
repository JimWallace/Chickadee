### Fixed

- **`get_server_info` reports each activity kind's real aggregation.** It said `leaderboard` for every kind, because `aggregatesToLeaderboard` was true for all six and the `standings` branch was dead, so a round robin, a tournament and the tests-and-code kind reported an aggregation their pages do not show. The payload now carries the kind's `ActivityAggregation` token, the schema enum is derived from the same cases, and the vestigial `aggregatesToLeaderboard` is deleted: every kind has a ranking page, so the leaderboard route and `leaderboardPath` ask only visibility (#1746).

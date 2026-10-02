### Changed

- **The seven activity and achievement persistence files live in `Services/`.** `ActivityMatches`, `Tournaments`, `ClassCorpus`, `ClassAchievements`, `ClassItemCoverage`, `LeaderboardEntries` and `ActivityUnion` are ingest-time persistence with no second surface, which is the Services rule. A move only (#1729).

### Fixed

- **The two leaderboard pages read the aggregation axis by name.** Present mode had a `default:` arm and the leaderboard page defined the metric board as "none of the other three", so a fifth aggregation would have rendered the metric board silently. Both now name `.leaderboard`, and a source scan pins it (#1745).

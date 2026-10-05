### Fixed

- **The standing badge and the standings-leader record follow the page rank.** The badge signal counted every row and broke ties by update time, and the leader record read rows of students who had left the course. One ranking rule, `rankedStandings`, now serves the leaderboard page, the badge signal and the record: tied students share a place, and a student who left has none.

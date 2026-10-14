### Fixed

- **The leaderboard page refreshes during a live session again.** Its results region carried the poll attributes, but the page never loaded `table-poll.js`, so the region did not refresh until a reload. Present mode was not affected. A filter typed into the leaderboard's filter box now stays applied after each refresh, and a refresh waits while the box has focus.

### Fixed

- **The leaderboard page refreshes during a live session again.** Its results region carried the poll attributes, but the page never loaded `table-poll.js`, so the region did not refresh until a reload. Present mode was not affected. A refresh now keeps the reader's place: a typed filter stays applied, with its "no match" message, the refresh waits while the filter box has focus, and the bracket keeps its horizontal scroll. A board in a live session shows its filter box from the first row, because the class arrives while it is open.

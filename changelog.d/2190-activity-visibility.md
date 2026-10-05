### Fixed

- **`set_activity` keeps a visible leaderboard visible.** An absent `leaderboardVisibility` reset the board to hidden, so an agent that only moved the session window during a live session hid the projected board from the class. An absent value now keeps the stored visibility while the kind is unchanged, as the opponent file and the window already do. A kind change starts hidden.

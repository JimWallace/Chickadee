### Fixed

- **Lists fit a phone.** The course page, the instructor Overview, Students, Slip days, LEARN, the leaderboard and the admin lists no longer scroll sideways on a 375px screen. At 640px and below each row wraps: tile, title, state, then the actions on their own line under the title. The tab bar scrolls to the active tab, and a few wide controls (the secret-test reveal, the facts buttons, the results tables) wrap or scroll inside themselves. The visual-regression run now captures the list pages at 375px and fails any page that scrolls sideways at 320px.
